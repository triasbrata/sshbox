import 'dart:async';

import 'package:file_picker/file_picker.dart';

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm2/xterm.dart';

import '../data/secret_store.dart';
import '../files/file_browser.dart';
import '../files/transfers.dart';
import '../git/git_diff.dart';
import '../platform.dart';
import '../session/session_manager.dart';
import '../session/tailnet_forwarder.dart';
import 'connect_sheet.dart';
import 'ctrl_click.dart';
import 'file_browser_page.dart';
import 'git_page.dart';
import 'key_bar.dart';
import 'magic_key.dart';
import 'settings_page.dart';
import 'terminal_link.dart';
import 'terminal_paste.dart';
import 'terminal_text_input.dart';
import 'tmux_panes.dart';
import 'toast.dart';

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
    required this.onOpenWeb,
    required this.onOpenChat,
    required this.onOpenGit,
    required this.onOpenDiff,
    required this.onSaveFileRoot,
  });

  final LiveSession session;
  final SecretStore secrets;

  /// Opens a file picked in the drawer as a tab of its own, next to this one;
  /// with [line], a search result's, at that line.
  final void Function(String path, {int? line}) onOpenFile;

  /// Opens a web link from this session in a tab of its own, next to this
  /// one — see [openUrl].
  final void Function(Uri url) onOpenWeb;

  /// Opens this session's chat with Claude in a tab beside this one.
  final VoidCallback onOpenChat;

  /// Opens this session's git panel in a tab beside this one.
  final VoidCallback onOpenGit;

  /// Opens a diff from the git panel in a file tab beside this one.
  final void Function(GitDiff diff) onOpenDiff;

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

  /// The upload under way from here, which the bar along the terminal's
  /// bottom edge follows.
  Transfer? _sending;

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

  /// While the host is asked which Claude Code it has, so a second tap does
  /// not ask again.
  bool _checkingClaude = false;

  /// Opens the chat once the host's Claude Code is one chat works with, and
  /// otherwise says why and opens nothing.
  Future<void> _openChat() async {
    setState(() => _checkingClaude = true);
    final why = await _session.chatRefusal();
    if (!mounted) return;
    setState(() => _checkingClaude = false);
    if (why == null) return widget.onOpenChat();
    // Five seconds, as an error has: a refusal asks the user to go and do
    // something about the host's Claude Code, which a second is too short to
    // read, let alone act on.
    showToast(
      context,
      why,
      type: ToastificationType.warning,
      duration: const Duration(seconds: 5),
    );
  }

  /// Forwards and problems already announced, so each is said once. Held by
  /// identity: a server that restarts is a new forward, and says so.
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

    // The session connected in its sheet before this page was built — its
    // PTY at a guessed size, which the terminal's first layout corrects —
    // so what came of that is taken in after the first frame: a tmux
    // problem to say, forwards already up, files shared into it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSessionChanged());
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
      showToast(
        context,
        'Not using tmux: $tmuxProblem',
        type: ToastificationType.error,
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
  ///
  /// One that cannot land says so in the same place, in red, with the reason
  /// under it — tailscale's own words, `--operator` and all — and stays long
  /// enough to read them. As a snack bar it came at the other end of the
  /// screen from the toast the user was waiting for.
  void _announceForwards() {
    // Held now rather than read when Open is pressed: the toast can outlive
    // this page, and a page that has gone has no context to read.
    final page = context;
    final inTab = widget.onOpenWeb;
    final forwarder = _session.forwarder;
    void failed(String what, String why) => showToast(
      context,
      '$what\n$why',
      type: ToastificationType.error,
      duration: const Duration(seconds: 8),
    );
    for (final forward in forwarder.forwards) {
      final address = forward.address;
      if (address == null && forward.error == null) continue;
      if (!_announced.add(forward)) continue;
      if (address != null) {
        showToast(
          context,
          'Port ${forward.port} is on $address',
          // Five seconds rather than a remark's one: time to reach for Open.
          duration: const Duration(seconds: 5),
          action: (
            label: 'Open',
            onPressed: () =>
                openUrl(page, Uri.parse('http://$address'), inTab: inTab),
          ),
        );
      } else {
        failed('Port ${forward.port} not forwarded', forward.error!);
      }
    }
    // One that goes — its server stopped, or forwarding did — says so in
    // passing, if it was ever on the tailnet to go from.
    final current = forwarder.forwards.toSet();
    for (final gone in _announced.whereType<PortForward>().toList()) {
      if (current.contains(gone)) continue;
      _announced.remove(gone);
      if (gone.address != null) showToast(context, 'Port ${gone.port} closed');
    }
    final problem = forwarder.problem;
    if (problem != null && _announced.add(problem)) {
      failed('Not forwarding ports', problem);
    }
  }

  /// Uploads a file handed to the session from outside the terminal page, and
  /// pastes a text, in the order they came.
  Future<void> _drainShared() async {
    if (_sending != null ||
        !_session.isConnected ||
        !_session.hasPendingUploads) {
      return;
    }
    // Opening a session replaces this page with a fresh one; only whichever is
    // actually on screen takes the queue, so the progress bar is visible and
    // no file is uploaded twice.
    if (ModalRoute.of(context)?.isCurrent != true) return;
    for (final share in _session.takePendingUploads()) {
      switch (share) {
        case SharedFile file:
          await _upload(file);
        case String text:
          final refused = await pasteShared(_session.terminal, text);
          if (refused != null && mounted) {
            showToast(context, refused, type: ToastificationType.warning);
          }
      }
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

  /// The same for the keys the bar, the pad and the magic key send: an armed
  /// modifier folds into a key of one character, so ALT with the magic key's
  /// Enter is ESC CR, a new line, and CTRL with a symbol is its control code.
  void _send(String data) {
    _letGo();
    _session.sendRaw(_keyBar.applyToKey(data));
  }

  void _letGo() {
    for (final view in _paneViews) {
      view.selection.clearSelection();
    }
  }

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
    setState(() {
      _gitDrawer = false;
      _browser ??= _session.openFileBrowser();
    });
    _scaffoldKey.currentState?.openEndDrawer();
  }

  /// Which panel the one end drawer holds: the file tree, or the git panel
  /// where Settings says the git button opens a drawer. A [Scaffold] has one
  /// drawer, so the button tapped last is what is in it — asking for the other
  /// one swaps the content of the drawer already open.
  bool _gitDrawer = false;

  /// Settings decides where the repositories show: a tab beside the shell, as
  /// they always did, or this page's own drawer over the terminal. It is read
  /// at the tap, so a change in Settings needs nothing reopened and leaves a
  /// git tab already open alone.
  void _openGit() {
    if (!gitInDrawer.value) {
      widget.onOpenGit();
      return;
    }
    setState(() => _gitDrawer = true);
    _scaffoldKey.currentState?.openEndDrawer();
  }

  /// The git panel in the drawer: the same [GitPage] the tab holds, at the
  /// file tree's width, with a button to shut the drawer since there is no tab
  /// ✕ here to do it.
  Widget _buildGitDrawer() => Drawer(
    width: math.min(360, MediaQuery.sizeOf(context).width * 0.85),
    child: GitPage(
      session: _session,
      onClose: _closeDrawer,
      // The diff goes to a tab beside this page, which the drawer would sit
      // over: shut it, so the tab that just opened is what the user sees.
      onOpenDiff: (diff) {
        _closeDrawer();
        widget.onOpenDiff(diff);
      },
    ),
  );

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
        initialScrollOffset: _browseScroll.root == _browseRoot
            ? _browseScroll.offset
            : 0,
        ownsBrowser: false,
        onRootChanged: (root) => _browseRoot = root,
        onExpandedChanged: (expanded) => _browseExpanded = expanded,
        onScrollChanged: (offset) =>
            _browseScroll = (root: _browseRoot, offset: offset),
        onSaveRoot: widget.onSaveFileRoot,
        terminal: _terminalLink,
        onClose: _closeDrawer,
        onFileSelected: _openFileTab,
      ),
    );
  }

  void _closeDrawer() => _scaffoldKey.currentState?.closeEndDrawer();

  /// A picked file becomes a tab of its own, beside this session's — the same
  /// answer on every size, so there is one place a file is ever opened.
  void _openFileTab(String path, {int? line}) {
    _closeDrawer();
    widget.onOpenFile(path, line: line);
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
    // The theme's accent, clear of the terminal's background in either
    // brightness.
    final color = Theme.of(context).colorScheme.primary;
    for (final view in _paneViews) {
      view.showLinks(ctrl: ctrl, color: color);
    }
  }

  /// The key bar's keyboard button: the way back to the soft keyboard, which
  /// a tap on the terminal is not once a hardware key has shut it. The pane
  /// being typed into gets it, or the first one when none holds focus.
  void _showKeyboard() {
    _PaneViewState? target;
    for (final view in _paneViews) {
      target ??= view;
      if (view.hasFocus) target = view;
    }
    target?.showKeyboard();
  }

  /// With Ctrl, opens the link under the tap and types nothing; without, asks
  /// for focus — and for the soft keyboard too, unless a hardware keyboard has
  /// typed, in which case reopening it would double the next key.
  ///
  /// An OSC 8 hyperlink under the tap comes first: the address its program
  /// gave it is what it means, where the text of its label is only what it
  /// shows. It is opened here rather than through xterm2's own
  /// `onHyperlinkTap`, which asks the hardware keyboard alone whether Ctrl is
  /// down and so would never hear the key bar's CTRL, the one a tablet with
  /// no keyboard has. Only ever on a Ctrl+tap: a hyperlink's address is
  /// hidden and was written by whatever program is running, so nothing opens
  /// one without being asked — and the selection menu's Copy link address
  /// shows where it goes first.
  void _onTerminalTap(_PaneViewState view, CellOffset cell) {
    if (!_ctrl) {
      view.requestKeyboard();
      return;
    }
    // Used up by the tap, link or not, the way a key uses it up.
    if (_keyBar.ctrl) _keyBar.toggleCtrl();
    final terminal = view.widget.terminal;
    final hyperlink = terminal.hyperlinkAt(cell);
    final link = hyperlink != null
        ? hyperlinkTarget(hyperlink)
        : linkAt(terminal.buffer, cell);
    if (link != null) unawaited(_openLink(link));
  }

  /// A URL opens in a web tab beside this one, a folder becomes the files
  /// drawer's root, and a file opens in a tab the way one picked in the
  /// drawer does.
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
      if (url != null) await openUrl(context, url, inTab: widget.onOpenWeb);
      return;
    }
    if (!_session.isConnected || !_session.canBrowseFiles) return;

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
          showToast(
            context,
            'Not a file or a folder: $path',
            type: ToastificationType.error,
          );
        case null:
          // A bare name only counted if it was there, so a miss on one is
          // nothing under the tap.
          if (link.kind == LinkKind.name) return;
          showToast(
            context,
            relative && cwd == null
                ? 'Not found: $path\nTaken from home: the host did not '
                      'say where the terminal is.'
                : 'Not found: $path',
            type: ToastificationType.error,
          );
      }
    } on FileBrowserException catch (error) {
      if (mounted) {
        showToast(context, error.message, type: ToastificationType.error);
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
    // A toast, which stacks rather than queues: following, every folder
    // tapped on the way down to a file can be refused, and as snack bars each
    // would wait its turn.
    void refuse(String why) {
      if (mounted) showToast(context, why, type: ToastificationType.warning);
    }

    var slow = false;
    final now = await _session.foreground().timeout(
      const Duration(milliseconds: 1500),
      onTimeout: () {
        slow = true;
        return null;
      },
    );
    if (now == null) {
      refuse(
        slow
            ? 'No answer from the host in time — not moving the shell'
            : 'The host cannot say what the shell is running — not moving it',
      );
    } else if (!now.shellInForeground) {
      refuse('${now.program} is running — not moving the shell');
    } else if (now.cwd != path) {
      _session.sendRaw('cd ${_shellQuote(path)}\n');
    }
  }

  /// Pick files, send each to `/tmp` on the host, then type each remote path
  /// at the prompt — so the next thing you write is a command that uses them.
  /// One at a time and in the order picked, as a share of several is, so the
  /// paths land on one line in that order.
  Future<void> _attachFile() async {
    for (final file in await FilePicker.pickFiles()) {
      final localPath = file.path;
      // Something picked from a cloud provider has no filesystem path, and so
      // nothing for SFTP to read.
      if (localPath == null) continue;
      await _upload((path: localPath, name: file.name));
    }
  }

  /// The one upload path: the paperclip and the share sheet both end here, so
  /// progress, the typed remote path and the error message cannot drift apart.
  Future<void> _upload(SharedFile file) async {
    if (!mounted) return;

    try {
      final remotePath = await transfers.run(
        name: file.name,
        host: _session.host.displayName,
        direction: TransferDirection.upload,
        work: (transfer) {
          setState(() => _sending = transfer);
          return _session.uploadToTmp(
            localPath: file.path,
            fileName: file.name,
            onProgress: transfer.report,
            cancel: transfer.cancelled,
          );
        },
      );

      // A trailing space so the path is ready to be followed by arguments.
      _session.sendRaw('$remotePath ');

      if (mounted) {
        showToast(
          context,
          'Uploaded to $remotePath',
          type: ToastificationType.success,
        );
      }
    } catch (error) {
      // Cancelled from the Transfers tab or the notification, which say so.
      final cancelled =
          error is FileBrowserException &&
          error.fault == FileBrowserFault.cancelled;
      if (mounted && !cancelled) {
        showToast(
          context,
          'Upload failed: $error',
          type: ToastificationType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      endDrawer: _gitDrawer ? _buildGitDrawer() : _buildFilesDrawer(),
      // Never by edge swipe: the terminal owns horizontal gestures, and having
      // the file list slide over the shell mid-command would be maddening.
      endDrawerEnableOpenDragGesture: false,
      // No app bar: the tab strip above already names the session, and the
      // page's two buttons ride in the key bar, where the thumb already is.
      // The font and size come from Settings, and a change there redraws
      // every terminal here at once, tmux's panes re-measured with them.
      body: ValueListenableBuilder(
        valueListenable: terminalSettings,
        builder: (context, style, _) => _buildBody(style),
      ),
      // In the Scaffold's own slot rather than the body so it rides above the
      // soft keyboard and the button below floats clear of it. Its keys are
      // the ones Settings arranged, redrawn the moment they change there.
      //
      // A desktop keeps the bar but not the keys: ESC, CTRL and the arrows
      // stand in for what a soft keyboard lacks, and there the keyboard has
      // them all — but the bar is also where this page's own buttons live,
      // the files drawer, upload, git and Claude, and taking the whole bar
      // away left no way to reach any of them.
      bottomNavigationBar: ValueListenableBuilder(
        valueListenable: keyBarSettings,
        builder: (context, _, _) => TerminalKeyBar(
          controller: _keyBar,
          terminal: _session.terminal,
          onEmit: _send,
          showKeys: _session.isConnected && !isDesktop,
          compact: isDesktop,
          keys: keyBarSettings.keys,
          customKeys: keyBarSettings.customKeys,
          leading: [
            IconButton(
              tooltip: 'Chat with Claude',
              onPressed:
                  (_session.isConnected &&
                      _session.canChat &&
                      !_checkingClaude)
                  ? _openChat
                  : null,
              icon: const Icon(Icons.forum_outlined),
            ),
            IconButton(
              tooltip: 'Git',
              onPressed: (_session.isConnected && _session.canGit)
                  ? _openGit
                  : null,
              icon: const Icon(Icons.account_tree_outlined),
            ),
            IconButton(
              tooltip: 'Browse files',
              onPressed: (_session.isConnected && _session.canBrowseFiles)
                  ? _openFiles
                  : null,
              icon: const Icon(Icons.folder_outlined),
            ),
            IconButton(
              tooltip: 'Upload a file to /tmp',
              onPressed:
                  (_session.isConnected &&
                      _session.canUploadFiles &&
                      _sending == null)
                  ? _attachFile
                  : null,
              icon: const Icon(Icons.attach_file),
            ),
            // The only way back to the soft keyboard once a hardware key has
            // shut it: a tap on the terminal cannot reopen it without making
            // the next key arrive twice. Always here, so a tablet out of its
            // keyboard case is never left without one — but a desktop has
            // no soft keyboard for it to bring back.
            if (!isDesktop)
              IconButton(
                tooltip: 'Show the keyboard',
                onPressed: _showKeyboard,
                icon: const Icon(Icons.keyboard_outlined),
              ),
          ],
        ),
      ),
    );
  }

  /// [style] is what every terminal on the page draws with. tmux's panes are
  /// laid out in cells of it, so it is one value rather than one per view.
  Widget _buildBody(TerminalStyle style) {
    final error = _session.error;
    if (error != null && !_session.isConnected) {
      return ConnectionError(
        message: error,
        // A tab brought back after its tmux session went: trying again finds
        // the same, so it offers a new one.
        retryLabel: _session.tmuxGone ? 'Start a new session' : null,
        onRetry: () {
          if (_session.tmuxGone) _session.startNewTmux();
          unawaited(
            connectInSheet(
              context,
              _session,
              secrets: widget.secrets,
              inTab: widget.onOpenWeb,
            ),
          );
        },
      );
    }

    final tmux = _session.tmux;
    final shown = tmux == null
        ? {_session.terminal}
        : {for (final pane in tmux.panes) pane.terminal};
    _views.removeWhere((terminal, _) => !shown.contains(terminal));

    return Stack(
      children: [
        // Both kinds of terminal take their size from here, the soft
        // keyboard's slide included: see _SettledHeight.
        _SettledHeight(
          child: tmux == null
              ? _paneView(
                  _session.terminal,
                  style,
                  focused: true,
                  padding: _padding,
                )
              : TmuxPaneLayout(
                  tmux: tmux,
                  textStyle: style,
                  padding: _padding,
                  // Touching a pane is what focuses it, and the session sends
                  // the bar's keys to the focused pane, so every pane sends
                  // through it.
                  pane: (pane, focused) => _paneView(
                    pane.terminal,
                    style,
                    focused: focused,
                    autoResize: false,
                  ),
                ),
        ),
        // Still at a sign-in once the connect sheet has sent it to a web
        // tab: the way back to that tab, rather than a blank terminal. Not
        // while a sheet is over the page, showing its own.
        if (_session.authUrl case final url?
            when _session.connecting &&
                ModalRoute.of(context)?.isCurrent != false)
          ColoredBox(
            // The page's own surface, which the prompt's text reads on in
            // either brightness.
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: AuthCheckPrompt(
                  url: url,
                  onOpen: () => widget.onOpenWeb(url),
                ),
              ),
            ),
          ),
        // Along the terminal's bottom edge, just above the key bar, rather
        // than in the bar's slot: growing the slot would shrink the terminal,
        // and resize the shell once when an upload starts and again when it
        // ends.
        if (_sending case final sending?)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            // Only the bar follows the transfer, a few times a second: the
            // page is built again only as it starts and ends.
            child: ListenableBuilder(
              listenable: transfers,
              builder: (_, _) =>
                  LinearProgressIndicator(value: sending.fraction),
            ),
          ),
        // In the body rather than the Scaffold's button slot so it can be
        // parked anywhere, and so its ring is free to open over the terminal.
        // Not on a desktop: it is a thumb's Enter key, and a mouse dragging it
        // around over the output is only in the way.
        if (_session.isConnected && !isDesktop)
          Positioned.fill(
            child: MagicKey(terminal: _session.terminal, onEmit: _send),
          ),
      ],
    );
  }

  Widget _paneView(
    Terminal terminal,
    TerminalStyle style, {
    required bool focused,
    bool autoResize = true,
    EdgeInsets? padding,
  }) => _PaneView(
    key: _views.putIfAbsent(terminal, GlobalKey.new),
    terminal: terminal,
    textStyle: style,
    onEmit: _send,
    onTap: _onTerminalTap,
    onImage: _upload,
    focused: focused,
    autoResize: autoResize,
    padding: padding,
  );
}

const _padding = EdgeInsets.all(6);

/// Gives the terminal a new height only once the room for it has stopped
/// changing, and until then keeps it at the height it had, its bottom row on
/// the key bar and whatever no longer fits cut off at the top.
///
/// The soft keyboard does not arrive in one step. Android slides it in over a
/// few hundred milliseconds and Flutter hands the app the inset of every
/// frame of that slide, so the room under the tab strip shrinks a little each
/// frame, and each time it loses a row the terminal was resized: xterm2 laid
/// the buffer out again and repainted it whole, and the host was sent a
/// window change — tmux a `refresh-client -C` — so the program in it redrew
/// for a size that was gone a frame later. One keyboard, a dozen resizes and
/// more, for every terminal tab at once, since the hidden ones sit laid out
/// in the same IndexedStack. On the tablet that ran at a handful of frames a
/// second, and Claude Code's redraws, each for a size already gone, arrived
/// out of step with the rows under them and mangled its input box until the
/// last one landed, half a second after the keyboard had stopped.
///
/// Held, the terminal is not laid out or painted again while the keyboard
/// moves: xterm2's view is a repaint boundary, so it is only moved, and the
/// one resize, the one window change and the one redraw come when the slide
/// is over. The bottom stays pinned above the key bar, as it will be after
/// the resize, so the prompt rides up with the keyboard rather than
/// vanishing under it. Growing — the keyboard going away — shows the
/// terminal's own background above it until then.
///
/// Height only: the keyboard never changes the width, and what does —
/// turning the tablet, a tab group's divider — keeps resizing as it goes.
class _SettledHeight extends StatefulWidget {
  const _SettledHeight({required this.child});

  final Widget child;

  /// How long the height must stay put to count as settled. A frame of the
  /// slide is 16 ms apart at most, so this is several frames of stillness,
  /// and short enough that the resize seems to come with the keyboard.
  static const settle = Duration(milliseconds: 150);

  @override
  State<_SettledHeight> createState() => _SettledHeightState();
}

class _SettledHeightState extends State<_SettledHeight> {
  double? _height;
  Timer? _settling;

  @override
  void dispose() {
    _settling?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: terminalThemeOf(context).background,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxHeight;
        // The first height is taken as it comes: there is nothing to hold.
        final held = _height ??= room;
        _settling?.cancel();
        // Back at the held height before it settled, a keyboard shown and
        // put away again at once, and nothing needs resizing at all.
        if (room != held) {
          _settling = Timer(_SettledHeight.settle, () {
            if (mounted) setState(() => _height = room);
          });
        }
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.bottomCenter,
            minHeight: held,
            maxHeight: held,
            child: widget.child,
          ),
        );
      },
    ),
  );
}

/// One terminal on the page, and what makes it usable by touch: the soft
/// keyboard's input, the swipe pad, and xterm2's view. A plain session shows
/// one; tmux shows one per pane, each with its own focus, scroll position and
/// selection.
class _PaneView extends StatefulWidget {
  const _PaneView({
    super.key,
    required this.terminal,
    required this.textStyle,
    required this.onEmit,
    required this.onTap,
    required this.onImage,
    required this.focused,
    this.autoResize = true,
    this.padding,
  });

  final Terminal terminal;
  final TerminalStyle textStyle;
  final void Function(String data) onEmit;
  final void Function(_PaneViewState view, CellOffset cell) onTap;

  /// Sends a pasted picture to the host and types its path at the prompt: the
  /// page's own upload, the paperclip's and the share sheet's.
  final Future<void> Function(SharedFile image) onImage;

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
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void didUpdateWidget(_PaneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.focused) _followFocus();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _focusNode.dispose();
    _scrollController.dispose();
    // Takes the underlines with it.
    selection.dispose();
    super.dispose();
  }

  /// There must always be exactly one live input path — [TerminalTextInput]'s
  /// IME connection or this pane's focused hardware keys — and never zero.
  ///
  /// The connection is shut for good once a hardware keyboard has typed, so
  /// focus is then the whole of it, and focus can fall into a hole: Flutter
  /// parks it on the enclosing scope, handing it to no one, whenever a
  /// focused node goes away, and a page that does not put it back leaves the
  /// terminal quietly unable to type. The user's only way out is to switch to
  /// another app and come back, which makes the platform hand the focus over
  /// again.
  ///
  /// A hardware key is seen here whether this pane has focus or not, and
  /// [HardwareKeyboard]'s handlers run before the focus chain is dispatched,
  /// so taking the focus back now lands this very key rather than the one
  /// after it.
  ///
  /// Only when the focus is parked on this pane's own scope: a dialog, a
  /// bottom sheet or the files drawer holds its own scope while it is open,
  /// and a field being typed into is a node rather than a scope, so neither
  /// is taken from. Watches only — the key still goes where it was going.
  bool _onHardwareKey(KeyEvent event) {
    if (_shown == true &&
        FocusManager.instance.primaryFocus == _focusNode.enclosingScope) {
      _followFocus(keyboard: false);
      // The pending change would otherwise be applied in a microtask, long
      // after this key has been dispatched into the hole.
      FocusManager.instance.applyFocusChangesIfNeeded();
    }
    return false;
  }

  /// Every paste into this pane, however it was asked for: the selection
  /// toolbar's Paste, and a hardware Ctrl+V, which xterm2 would otherwise
  /// answer itself with text alone.
  ///
  /// An image goes to the host as a file and its remote path is typed at the
  /// prompt, since a byte stream has nothing to do with a picture and a
  /// program on the host cannot see the tablet's clipboard. The upload says
  /// its own piece; a clipboard that cannot be taken, or that holds nothing
  /// this can use, is said here — a paste must never look like nothing
  /// happened.
  Future<void> _paste() async {
    try {
      await pasteIntoTerminal(
        widget.terminal,
        upload: widget.onImage,
        onNothing: _say,
      );
    } on PlatformException catch (error) {
      _say(error.message ?? 'That picture could not be pasted');
    }
  }

  /// A picture the soft keyboard committed — Gboard's clipboard strip — which
  /// arrives as bytes rather than through the clipboard.
  Future<void> _pasteContent(KeyboardInsertedContent content) async {
    try {
      final image = await insertedImage(content);
      if (image != null) await widget.onImage(image);
    } on PlatformException catch (error) {
      _say(error.message ?? 'That picture could not be pasted');
    }
  }

  void _say(String message) {
    if (!mounted) return;
    showToast(context, message, type: ToastificationType.warning);
  }

  /// Ctrl+V — ⌘V on an Apple platform — before xterm2's own paste shortcut
  /// sees it, that one reading text and nothing else. Every other key is left
  /// exactly as it was.
  ///
  /// A held Ctrl+V pastes once. Android repeats a held key about 20 times a
  /// second, and each repeat is a [KeyRepeatEvent] rather than a
  /// [KeyDownEvent]; those used to fall past this to xterm2's own shortcut,
  /// whose [SingleActivator] takes repeats, so half a second of holding the
  /// key ran three more clipboard reads — visible in the tablet's log as three
  /// "Clipboard text was unable to be received from content URI" in 100 ms.
  /// They are claimed here and dropped instead: one press is one paste, and a
  /// picture is never uploaded again and again because a thumb stayed down.
  KeyEventResult _onPasteChord(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || event.logicalKey != LogicalKeyboardKey.keyV) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    // The same combination xterm2's own activator takes, so nothing that used
    // to reach the shell — ^V, Ctrl+Shift+V — stops reaching it.
    if (keys.isShiftPressed || keys.isAltPressed) return KeyEventResult.ignored;
    final chord = switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => keys.isMetaPressed,
      _ => keys.isControlPressed && !keys.isMetaPressed,
    };
    if (!chord) return KeyEventResult.ignored;
    if (event is KeyDownEvent) unawaited(_paste());
    return KeyEventResult.handled;
  }

  /// Ctrl+Shift+C — ⌘C on an Apple platform — before xterm2's own copy
  /// shortcut, which reads the selection through `Buffer.getText` and so
  /// glues together words a program spaced with cursor moves: see
  /// [selectedText]. The same combination xterm2's activator takes, and like
  /// it, claimed with nothing selected too.
  KeyEventResult _onCopyChord(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || event.logicalKey != LogicalKeyboardKey.keyC) {
      return _onPasteChord(node, event);
    }
    final keys = HardwareKeyboard.instance;
    final chord = switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS =>
        keys.isMetaPressed &&
            !keys.isControlPressed &&
            !keys.isShiftPressed &&
            !keys.isAltPressed,
      _ =>
        keys.isControlPressed &&
            keys.isShiftPressed &&
            !keys.isAltPressed &&
            !keys.isMetaPressed,
    };
    if (!chord) return KeyEventResult.ignored;
    final range = selection.selection;
    if (event is KeyDownEvent && range != null) {
      unawaited(
        Clipboard.setData(
          ClipboardData(text: selectedText(widget.terminal.buffer, range)),
        ),
      );
    }
    return KeyEventResult.handled;
  }

  /// Whether the tabs were showing this pane when it last looked; null until
  /// its first look.
  bool? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Back on screen after another tab, typing comes back here. The tabs'
    // IndexedStack says which page is showing. Only on the way back: a tab
    // built on screen has autofocus, and raises the keyboard as a new shell
    // always has. After the frame, so a page leaving the screen in the same
    // build cannot take the focus back off it.
    final shown = Visibility.of(context);
    if (shown && _shown == false) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _followFocus(keyboard: false),
      );
    }
    _shown = shown;
  }

  /// Typing goes wherever Flutter's focus is, and the key bar wherever
  /// tmux's is: the two are kept on the same pane. Without [keyboard] the
  /// focus comes without the soft keyboard, since [TerminalTextInput] raises
  /// it only for a focus that still holds its keyboard token.
  void _followFocus({bool keyboard = true}) {
    if (mounted && widget.focused && !_focusNode.hasFocus) {
      _focusNode.requestFocus();
      if (!keyboard) _focusNode.consumeKeyboardToken();
    }
  }

  void requestKeyboard() => _inputKey.currentState?.requestKeyboard();

  bool get hasFocus => _focusNode.hasFocus;

  /// The keyboard button's ask, which outranks a hardware keyboard.
  void showKeyboard() => _inputKey.currentState?.showKeyboard();

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
    // The tap is held back, because a program reading the mouse would
    // otherwise take a Ctrl+tap as a click and the link would never open.
    // The scroll is not: suspending every pointer input, as this used to,
    // took scrolling away too, and on the alternate screen or under a
    // program that reads the mouse — Claude Code, vim, less, tmux — a drag
    // is the only way a finger can scroll at all, there being no wheel. So
    // an armed CTRL froze the terminal's content until the app was killed.
    selection.setPointerInputs(
      ctrl ? _ctrlPointerInputs : _defaultPointerInputs,
    );
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

  /// What a terminal normally takes: xterm2's own default.
  static const _defaultPointerInputs = PointerInputs({
    PointerInput.tap,
    PointerInput.scroll,
  });

  /// The same without the tap, which Ctrl has claimed for opening links.
  static const _ctrlPointerInputs = PointerInputs({PointerInput.scroll});

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
      onContent: _pasteContent,
      child: SwipeKeyPad(
        terminal: widget.terminal,
        controller: selection,
        onEmit: widget.onEmit,
        onPaste: _paste,
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
          // Asked before xterm2's own shortcuts, and it claims the copy and
          // paste chords alone.
          onKeyEvent: _onCopyChord,
          // Tapping a terminal that already has focus is how you ask for the
          // keyboard back, and focus alone will not raise it.
          onTapUp: (_, cell) => widget.onTap(this, cell),
          padding: widget.padding,
          textStyle: widget.textStyle,
          // The theme picked in Settings: a new pick repaints the shell at
          // once, with no reconnect.
          theme: terminalThemeOf(context),
        ),
      ),
    );
  }
}

/// The schemes [openUrl] opens: a web page, and a mail or a call, which the
/// phone hands to a composer or a dialer that sends nothing until the user
/// says so there.
///
/// Everything else is refused, because nearly every link that reaches here
/// was written by somebody else: a program's output in the terminal, which
/// can hide any address behind any label with an OSC 8 hyperlink, a Markdown
/// file on the host, a reply in a chat that quotes what Claude read, a web
/// page in a tab, which can navigate with no tap at all. Handed to the phone,
/// an `intent:` names an activity to start, a `file:` a file on the phone,
/// and this app's own `sshbox://host/<id>` connects to a saved host — and the
/// label beside it could have said "open the docs". An allowlist rather than
/// a list of the bad ones, since any app installed can answer to a scheme of
/// its own.
const _opens = {'http', 'https', 'mailto', 'tel'};

/// Opens a link without leaving the app. Every link the app opens goes
/// through here — a Ctrl+tap, a forwarded port, a sign-in check, the Markdown
/// preview, a chat, a web tab handing on what it will not show — so this is
/// the one place that decides what may be opened at all: see [_opens]. What
/// is refused says so, and its address can still be copied, so a link the
/// user does mean to follow is one paste away rather than lost — by the
/// toast's Copy and never unasked, since a web page gets here with no tap and
/// must not be able to fill the clipboard.
///
/// A web page opens in a tab of our own beside the shell it came from:
/// [inTab] puts it there. With no shell to put it beside — the web tab's own
/// Open in browser, or a toast that outlived its page — it goes to a Custom
/// Tab instead, which the phone's default browser draws over this app with
/// its own engine, cookies and sign-ins, and Back returns from.
///
/// A browser that cannot draw a Custom Tab takes the link as a page of its
/// own instead; a `mailto:` or `tel:` goes wherever the phone sends it. When
/// nothing takes it the user is told, rather than left tapping a dead link.
///
/// [context] is only read while it is still mounted: a toast's Open can
/// outlive the page that showed it, and the session with it.
Future<void> openUrl(
  BuildContext context,
  Uri url, {
  void Function(Uri url)? inTab,
}) async {
  // Dart keeps a scheme in lower case, so `HTTPS:` and `Tel:` are here too.
  if (!_opens.contains(url.scheme)) {
    if (!context.mounted) return;
    showToast(
      context,
      url.hasScheme
          ? 'Not opened: a ${url.scheme}: link is not a web, mail or phone link'
          : 'Not opened: $url is not a web, mail or phone link',
      type: ToastificationType.warning,
      // Time to read why, and to reach for Copy.
      duration: const Duration(seconds: 5),
      action: (
        label: 'Copy',
        onPressed: () =>
            unawaited(Clipboard.setData(ClipboardData(text: '$url'))),
      ),
    );
    return;
  }
  // A desktop has a browser of its own, with the user's own extensions,
  // sessions and bookmarks; a web tab drawn by the system web view has none of
  // them, and no address bar worth the name. So every link there goes out to
  // that browser and no web tab is ever opened.
  final web = url.isScheme('http') || url.isScheme('https');
  if (web && inTab != null && !isDesktop && context.mounted) {
    inTab(url);
    return;
  }
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
    showToast(context, 'No app can open $url', type: ToastificationType.error);
  }
}

/// Why the shell is not up, with Try again, and in the connect sheet a Close
/// beside it, which gives the connect up.
class ConnectionError extends StatelessWidget {
  const ConnectionError({
    super.key,
    required this.message,
    required this.onRetry,
    this.onClose,
    this.retryLabel,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onClose;

  /// What the retry button says instead of Try again, when trying again as
  /// it was would not help.
  final String? retryLabel;

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
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onClose != null) ...[
                  TextButton(onPressed: onClose, child: const Text('Close')),
                  const SizedBox(width: 8),
                ],
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: Text(retryLabel ?? 'Try again'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
