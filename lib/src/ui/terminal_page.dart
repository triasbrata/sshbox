import 'dart:async';
import 'dart:convert';
import 'dart:io' show FileSystemEntity, FileSystemEntityType;

import 'package:desktop_drop/desktop_drop.dart';

import 'package:file_picker/file_picker.dart';

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        kDoubleTapTouchSlop,
        kMiddleMouseButton,
        kPrimaryMouseButton,
        kSecondaryMouseButton,
        PointerDeviceKind,
        PointerPanZoomStartEvent,
        PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm2/xterm.dart';

import '../data/secret_store.dart';
import '../files/file_browser.dart';
import '../files/transfers.dart';
import '../git/git_diff.dart';
import '../platform.dart';
import '../session/clipboard_terminal.dart';
import '../session/local_transport.dart' show localHostId;
import '../session/session_manager.dart';
import '../session/tailnet_forwarder.dart';
import 'connect_sheet.dart';
import 'ctrl_click.dart';
import 'file_browser_page.dart';
import 'file_download.dart';
import 'git_page.dart';
import 'key_bar.dart';
import 'magic_key.dart';
import 'mermaid_view.dart' show mermaidSource, showMermaidDialog;
import 'pane_menu.dart';
import 'right_click.dart';
import 'settings_page.dart';
import 'terminal_link.dart';
import 'terminal_paste.dart';
import 'terminal_text_input.dart';
import 'text_size.dart';
import 'tmux_panes.dart';
import 'toast.dart';
import 'tui.dart';

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

  /// Files are being dragged over this terminal, from the OS file manager.
  bool _dropping = false;

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
      type: TuiToastType.warning,
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
        type: TuiToastType.error,
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
      type: TuiToastType.error,
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
            showToast(context, refused, type: TuiToastType.warning);
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

  /// Whether a tap now is a Ctrl+tap: CTRL latched on the bar, or the link
  /// key held on a hardware keyboard — which covers a mouse click with it
  /// too. That key is Ctrl on a phone, and on a desktop whichever Settings
  /// picked, ⌘ by default on a Mac: see [LinkModifierSetting]. The other one
  /// then opens nothing, and its click reaches the program as a click.
  bool get _ctrl => _keyBar.ctrl || linkModifier.chosen.isPressed;

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
      final (:path, :cwd) = await _hostPath(target);
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
            type: TuiToastType.error,
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
            type: TuiToastType.error,
          );
      }
    } on FileBrowserException catch (error) {
      if (mounted) {
        showToast(context, error.message, type: TuiToastType.error);
      }
    }
  }

  /// Where [target], a path as the terminal shows it, is on the host. A
  /// relative one starts from the program that printed it, the terminal's
  /// foreground process, and from home when the host cannot say; [cwd] is
  /// where it started, or null when it did not start from there.
  Future<({String path, String? cwd})> _hostPath(String target) async {
    final relative = !target.startsWith('/') && !target.startsWith('~');
    final cwd = relative ? (await _session.foreground())?.cwd : null;
    final path = RemotePath.normalize(
      cwd != null
          ? RemotePath.join(cwd, target)
          : RemotePath.resolve(
              target,
              target.startsWith('/')
                  ? '/'
                  : await _session.fileBrowser.resolveHome(),
            ),
    );
    return (path: path, cwd: cwd);
  }

  /// A desktop's right-click in [view]: iTerm2's pane menu, as far as Jeansh
  /// has its items (see [paneMenuEntries]), the tab's own among them.
  void _paneMenu(_PaneViewState view, Offset at, CellOffset cell) {
    final terminal = view.widget.terminal;
    final range = view.selection.selection;
    final link =
        terminal.hyperlinkAt(cell) ??
        (range == null ? null : hyperlinkIn(terminal, range));
    final selected = range == null
        ? null
        : selectedText(terminal.buffer, range);
    void copy(String text, String said) {
      Clipboard.setData(ClipboardData(text: text));
      showToast(context, said, type: TuiToastType.success);
    }

    final files = _session.isConnected && _session.canBrowseFiles;
    final tmux = _session.tmux;
    final pane = tmux?.panes.where((p) => p.terminal == terminal).firstOrNull;
    final buffer = terminal.buffer;
    // The Mermaid source the selection holds, where a web view can draw it.
    final diagram = selected == null || !hasWebView
        ? null
        : mermaidSource(selected);
    showActionsAt(
      context,
      at,
      paneMenuEntries(
        context,
        at,
        PaneMenu(
          selected: selected,
          link: link,
          tab: TabMenu.of(context)?.actions?.call(),
          copy: selected == null ? null : () => copy(selected, 'Copied'),
          paste: () => unawaited(view._paste()),
          copyLink: link == null ? null : () => copy(link, 'Copied $link'),
          openUrl: (url) =>
              unawaited(openUrl(context, url, inTab: widget.onOpenWeb)),
          open: (link) => unawaited(_openLink(link)),
          download: files ? (path) => unawaited(_download(path)) : null,
          showDiagram: diagram == null
              ? null
              : () => unawaited(showMermaidDialog(context, diagram)),
          selectAll: () => view.selection.setSelection(
            buffer.createAnchor(0, 0),
            buffer.createAnchor(terminal.viewWidth, buffer.height - 1),
          ),
          // What has scrolled off, here and, in a tmux pane, tmux's own:
          // CSI 3 J, as `clear` sends it.
          clearBuffer: () {
            terminal.write('\x1b[3J');
            if (pane != null) tmux!.clearHistory(pane).ignore();
          },
          // RIS, as `reset` sends it: on this side only, the program on the
          // host left as it is.
          reset: () => terminal.write('\x1bc'),
        ),
      ),
    );
  }

  /// [target], a path on the host as the terminal shows it, down to this
  /// device, as the files drawer's Download brings one.
  Future<void> _download(String target) async {
    try {
      final (:path, cwd: _) = await _hostPath(target);
      if (!mounted) return;
      await downloadFile(
        context,
        _session.fileBrowser,
        path,
        host: _session.fileTabHost,
        onTransfer: (_) {},
      );
    } on FileBrowserException catch (error) {
      if (mounted) showToast(context, error.message, type: TuiToastType.error);
    }
  }

  /// Wraps a path so the shell sees exactly these characters.
  ///
  /// A path picked out of a listing can hold spaces, or anything else the
  /// shell would act on rather than pass along.
  static String _shellQuote(String path) => LiveSession.shellQuote(path);

  /// Puts a path at the prompt, ready for a command to be written around it.
  /// Never one holding a control character, which the shell would act on as
  /// a key: see [LiveSession.hasControl].
  void _typePath(String path) {
    if (LiveSession.hasControl(path)) {
      showToast(
        context,
        LiveSession.controlRefusal,
        type: TuiToastType.warning,
      );
      return;
    }
    _session.sendRaw('${_shellQuote(path)} ');
  }

  /// Puts a file's path at the prompt the way a drop in iTerm2 does, with a
  /// trailing space so it is ready to be followed by arguments.
  ///
  /// As a paste when the program asked for bracketed paste: Claude Code
  /// turns a pasted image path into [Image #N], while typed keys stay text.
  /// The space goes inside the brackets — Claude trims it, a shell keeps it;
  /// outside, it lands before the chip, which Claude inserts only after
  /// reading the file. Otherwise typed.
  void _pastePath(String path) {
    final terminal = _session.terminal;
    if (terminal.bracketedPasteMode) {
      terminal.paste('$path ');
    } else {
      _session.sendRaw('$path ');
    }
  }

  /// A dropped path escaped as iTerm2 escapes one: a backslash before every
  /// character a shell would read. Measured on Claude Code 2.1.280, the
  /// escaped form pasted still becomes [Image #N] while a single-quoted one
  /// stays text — and a bracketed-paste shell (bash 5.1+) needs it escaped
  /// just as a plain one does.
  static String _dropEscape(String path) =>
      path.replaceAllMapped(RegExp(r'[^A-Za-z0-9._/-]'), (m) => '\\${m[0]}');

  /// Files dropped from the OS file manager, one after another in order.
  ///
  /// A Mac or Linux Local shell runs on this machine, so the file's own path
  /// is pasted and nothing copied. Everywhere else — a host over SSH, a WSL
  /// distro, Windows' PowerShell — it goes through [_upload], as the
  /// paperclip's pick does, which says how it went itself.
  Future<void> _dropped(DropDoneDetails details) async {
    setState(() => _dropping = false);
    final here =
        _session.host.id == localHostId &&
        defaultTargetPlatform != TargetPlatform.windows;
    for (final item in details.files) {
      final path = item.path;
      final kind = FileSystemEntity.typeSync(path);
      if (here && path.runes.any((c) => c < 0x20 || c == 0x7f)) {
        // A backslash cannot make a newline or a CR in a name harmless at a
        // prompt that is not bracketed.
        if (mounted) {
          showToast(
            context,
            'Not pasted: the name holds a control character: ${item.name}',
            type: TuiToastType.warning,
          );
        }
      } else if (here && kind != FileSystemEntityType.notFound) {
        _pastePath(_dropEscape(path));
      } else if (kind == FileSystemEntityType.file && _session.canUploadFiles) {
        await _upload((path: path, name: item.name));
      } else if (mounted) {
        showToast(
          context,
          kind == FileSystemEntityType.directory
              ? 'A folder cannot be uploaded: ${item.name}'
              : 'Not a file on this computer: ${item.name}',
          type: TuiToastType.warning,
        );
      }
      if (!mounted) return;
    }
  }

  /// Sends the shell to a directory through [LiveSession.changeDirectory],
  /// which types nothing unless the shell is at its prompt, and says why.
  ///
  /// A toast, which stacks rather than queues: following, every folder
  /// tapped on the way down to a file can be refused, and as snack bars each
  /// would wait its turn.
  Future<void> _cdTo(String path) async {
    final why = await _session.changeDirectory(path);
    if (why != null && mounted) {
      showToast(context, why, type: TuiToastType.warning);
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

      // Its name is scrubbed to characters no shell reads, so typed bare.
      _pastePath(remotePath);

      if (mounted) {
        showToast(
          context,
          'Uploaded to $remotePath',
          type: TuiToastType.success,
        );
      }
    } catch (error) {
      // Cancelled from the Transfers tab or the notification, which say so.
      final cancelled =
          error is FileBrowserException &&
          error.fault == FileBrowserFault.cancelled;
      if (mounted && !cancelled) {
        showToast(context, 'Upload failed: $error', type: TuiToastType.error);
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
      body: _dropTarget(
        ValueListenableBuilder(
          valueListenable: terminalSettings,
          builder: (context, style, _) => _buildBody(style),
        ),
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
                  (_session.isConnected && _session.canChat && !_checkingClaude)
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

  /// On a desktop, files dropped from the OS file manager: see [_dropped].
  /// Only while this tab is the one showing and nothing covers it, since the
  /// plugin hands a drop to every target enabled under the pointer, and the
  /// tabs' IndexedStack lays the hidden ones out right there.
  Widget _dropTarget(Widget child) {
    if (!isDesktop) return child;
    final enable =
        _session.isConnected &&
        Visibility.of(context) &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    final theme = Theme.of(context);
    return DropTarget(
      enable: enable,
      onDragEntered: (_) => setState(() => _dropping = true),
      onDragExited: (_) => setState(() => _dropping = false),
      onDragDone: _dropped,
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (_dropping && enable)
            IgnorePointer(
              child: DecoratedBox(
                key: const ValueKey('drop-highlight'),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  border: Border.all(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
              ),
            ),
        ],
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
        // keyboard's slide included: see _SettledHeight. At the content
        // size alone, so the UI size never changes a cell: see ContentText.
        ContentText(
          scale: false,
          child: _SettledHeight(
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
              builder: (_, _) => TuiProgressBar(value: sending.fraction),
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
    onContextMenu: _paneMenu,
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
/// vanishing under it. Growing — the keyboard going away — takes the height
/// with no keyboard as the slide starts, so the rows are uncovered as the
/// keyboard leaves rather than a band of background showing until the resize.
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

  /// The keyboard's inset when [_height] was taken: above nothing, a
  /// keyboard was up and growing is it going away.
  double _heldInset = 0;

  /// The room seen with no keyboard at [_width], where a keyboard going away
  /// leaves the terminal.
  double? _open;
  double? _width;

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
        final inset = View.of(context).viewInsets.bottom;
        if (constraints.maxWidth != _width) {
          _width = constraints.maxWidth;
          _open = null;
        }
        if (inset == 0) _open = room;
        // The first height is taken as it comes: there is nothing to hold.
        var held = _height ??= room;
        // The keyboard going away: take the height it will leave at once,
        // the room the page had with no keyboard, rather than hold the
        // smaller one and show a band of background above it for the slide
        // and the settle. The terminal is laid out and resized once, as the
        // slide starts, its top cut off until the keyboard has gone, so the
        // rows are there as they come into view and the host has redrawn by
        // then. A desktop's window, with no keyboard, still waits to settle.
        if (room > held && _heldInset > 0 && (_open ?? 0) > held) {
          held = _height = math.max(_open!, room);
        }
        if (held == room) _heldInset = inset;
        _settling?.cancel();
        // Back at the held height before it settled, a keyboard shown and
        // put away again at once, and nothing needs resizing at all.
        if (room != held) {
          _settling = Timer(_SettledHeight.settle, () {
            if (mounted) {
              setState(() {
                _height = room;
                _heldInset = inset;
              });
            }
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
/// How a mouse gesture holding the selection grows: by words from a double
/// click, by lines from a triple click, or from the end of one already made
/// by a click with Shift.
enum _Grain { word, line, extend }

/// The pane's selection. While a mouse gesture [owned] it — see
/// [_PaneViewState._selectByClicks] — xterm2's own recognizers, which select
/// and clear on the same presses, are ignored, and only [own] changes it.
class _PaneSelection extends TerminalController {
  _PaneSelection({super.pointerInputs});

  bool owned = false;
  bool _own = false;

  void own(void Function() body) {
    _own = true;
    try {
      body();
    } finally {
      _own = false;
    }
  }

  @override
  void setSelection(CellAnchor base, CellAnchor extent, {SelectionMode? mode}) {
    if (owned && !_own) {
      base.dispose();
      extent.dispose();
      return;
    }
    super.setSelection(base, extent, mode: mode);
  }

  @override
  void clearSelection() {
    if (owned && !_own) return;
    super.clearSelection();
  }
}

class _PaneView extends StatefulWidget {
  const _PaneView({
    super.key,
    required this.terminal,
    required this.textStyle,
    required this.onEmit,
    required this.onTap,
    required this.onContextMenu,
    required this.onImage,
    required this.focused,
    this.autoResize = true,
    this.padding,
  });

  final Terminal terminal;
  final TerminalStyle textStyle;
  final void Function(String data) onEmit;
  final void Function(_PaneViewState view, CellOffset cell) onTap;

  /// A desktop's right-click on the pane: the page's own menu, see
  /// [_TerminalPageState._paneMenu].
  final void Function(_PaneViewState view, Offset at, CellOffset cell)
  onContextMenu;

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
  /// What xterm2 itself sends a program that reads the mouse: see
  /// [_pointerInputs].
  final selection = _PaneSelection(pointerInputs: _pointerInputs(false));

  /// A press [_mouseDown] sent and whose release has not gone yet, with where
  /// the pointer last was: xterm2 sends the moves between them.
  bool get _holding => (_tracked?.pointer ?? -1) != -1;
  List<TerminalUnderline> _underlines = const [];

  @override
  void initState() {
    super.initState();
    // A pane born focused — tmux focuses the one a split makes — takes focus
    // from the pane that had it, which autofocus alone would leave alone.
    WidgetsBinding.instance.addPostFrameCallback((_) => _followFocus());
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    FocusManager.instance.addListener(_onFocusMoved);
    // Before the view's own, which it would otherwise put there itself: see
    // [_programCopied].
    widget.terminal.onClipboardStore = _programCopied;
  }

  @override
  void didUpdateWidget(_PaneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      _letGoOfClipboard(oldWidget.terminal);
      widget.terminal.onClipboardStore = _programCopied;
    }
    if (!oldWidget.focused) _followFocus();
  }

  /// A pane going away mid-drag — its tab closed, its tmux pane gone — still
  /// lets the button go for the program, or Claude Code would go on dragging.
  /// Here rather than in [dispose], which runs once the terminal view below
  /// is gone and nothing can be sent through it; and from where the pointer
  /// was last, the render object being detached by now.
  @override
  void deactivate() {
    final tracked = _tracked;
    if (tracked != null && _holding) {
      _sendAt(tracked.button, TerminalMouseButtonState.up, tracked.at);
      _tracked = null;
      selection.setPointerInputs(_pointerInputs(false));
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _letGoOfClipboard(widget.terminal);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    FocusManager.instance.removeListener(_onFocusMoved);
    _clickTimer?.cancel();
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

  /// The same hole, filled as focus falls into it rather than at the next
  /// key: a tab group's pane given focus hands it to its own scope, which
  /// gives it to no one, and a menu opened from the pane then gave it back to
  /// the scope as it closed.
  void _onFocusMoved() {
    if (_shown == true &&
        FocusManager.instance.primaryFocus == _focusNode.enclosingScope) {
      _followFocus(keyboard: false);
    }
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
    showToast(context, message, type: TuiToastType.warning);
  }

  void _letGoOfClipboard(Terminal terminal) {
    if (terminal.onClipboardStore == _programCopied) {
      terminal.onClipboardStore = null;
    }
  }

  /// A program on the host copying — Claude Code's `/copy`, a yank in vim or
  /// tmux — with OSC 52 or the iTerm2 and kitty ways of saying it: see
  /// [ClipboardTerminal]. Only the terminal being typed into may, as xterm2's
  /// own rule has it, so a program in a tab out of sight cannot fill the
  /// clipboard, and it never happens without a word.
  void _programCopied(String _, String text) {
    if (!mounted || !_focusNode.hasFocus || text.isEmpty) return;
    // iTerm2's CopyToClipboard takes whatever is printed until its EndCopy,
    // which [ClipboardTerminal] never sees.
    if (utf8.encode(text).length > maxClipboardBytes) return;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    showToast(context, 'Copied from the terminal', type: TuiToastType.success);
  }

  /// The selection as the mouse button went down, to tell one the mouse has
  /// just made from one that was there already: see [_mouseUp].
  BufferRange? _selectionAtDown;

  void _mouseDown(PointerDownEvent event) {
    _rightDown(event);
    // A second pointer — a touchscreen, a pen — must not lose the held
    // press its release: the program would drag for ever.
    if (_holding) return;
    _tracked = null;
    if (event.kind != PointerDeviceKind.mouse) return;
    _selectionAtDown = selection.selection;
    final button = switch (event.buttons) {
      kPrimaryMouseButton => TerminalMouseButton.left,
      // The right button is Jeansh's, for its menu: see [_contextMenu].
      kMiddleMouseButton => TerminalMouseButton.middle,
      _ => null,
    };
    if (button == TerminalMouseButton.left && !_tracksDrags) {
      _selectByClicks(event);
    }
    if (button == null || !_tracksDrags) return;
    if (_send(button, TerminalMouseButtonState.down, event.position)) {
      _tracked = (
        pointer: event.pointer,
        button: button,
        at: _local(event.position),
      );
      selection.setPointerInputs(_pointerInputs(true));
    }
  }

  /// How long after a press the next still counts as the same run of
  /// clicks: macOS's and Windows's default double-click interval. Flutter's
  /// own 300 ms, [kDoubleTapTimeout], is a touch's, and a mouse's second
  /// press on a loaded machine, or a slower hand, comes later: it was
  /// counted as a first click and xterm2's drag of characters took over.
  static const _doubleClickInterval = Duration(milliseconds: 500);

  /// Clicks in a row on one spot, and the timer that ends the run.
  int _clicks = 0;
  Offset _clickAt = Offset.zero;
  Timer? _clickTimer;

  /// The mouse gesture that owns [selection] until its button comes up: the
  /// pointer, where it began, and how it selects.
  ({int pointer, int device, Offset anchor, _Grain grain, BufferRange? base})?
  _gesture;

  /// A double click selects the word under the pointer, a triple click its
  /// line, and a drag held from that click goes on word by word, line by
  /// line, as Terminal.app's and iTerm2's do. A click with Shift held
  /// extends the selection already there to the cell clicked, and a drag
  /// from it moves that end.
  ///
  /// xterm2 does this itself only while its tap recognizer wins: its press
  /// becomes a tap down after 100 ms, so a drag begun sooner never selects
  /// the word, and one begun later has its word replaced by a selection of
  /// characters from the press, `selectCharacters`. So the clicks are
  /// counted here, on the pointer events, which always arrive, and
  /// [selection] ignores xterm2 until the button is up.
  ///
  /// For the mouse, wherever there is one: a program tracking drags (see
  /// [_tracksDrags], desktop alone) keeps the clicks for itself, so a mouse
  /// on Android is counted too, a touch never.
  void _selectByClicks(PointerDownEvent event) {
    _endGesture();
    final render = _viewKey.currentState?.renderTerminal;
    if (render == null || _ctrlArmed) return;
    final near =
        _clickTimer != null &&
        (event.position - _clickAt).distance <= kDoubleTapTouchSlop;
    _clickTimer?.cancel();
    _clicks = near ? math.min(_clicks + 1, 3) : 1;
    _clickAt = event.position;
    _clickTimer = Timer(_doubleClickInterval, () {
      _clicks = 0;
      _clickTimer = null;
    });

    final anchor = render.globalToLocal(event.position);
    final base = selection.selection?.normalized;
    if (_clicks >= 2) {
      final grain = _clicks == 2 ? _Grain.word : _Grain.line;
      _gesture = (
        pointer: event.pointer,
        device: event.device,
        anchor: anchor,
        grain: grain,
        base: null,
      );
      selection.owned = true;
      _selectTo(anchor);
    } else if (HardwareKeyboard.instance.isShiftPressed && base != null) {
      _gesture = (
        pointer: event.pointer,
        device: event.device,
        anchor: anchor,
        grain: _Grain.extend,
        base: base,
      );
      selection.owned = true;
      _selectTo(anchor);
    }
  }

  void _selectTo(Offset to) {
    final gesture = _gesture;
    final render = _viewKey.currentState?.renderTerminal;
    if (gesture == null || render == null) return;
    selection.own(() {
      switch (gesture.grain) {
        case _Grain.word:
          render.selectWord(gesture.anchor, to);
        case _Grain.line:
          render.selectLine(gesture.anchor, to);
        case _Grain.extend:
          final base = gesture.base!;
          final target = render.getCellOffset(to);
          final cell = target.isAfterOrSame(base.end)
              ? CellOffset(target.x + 1, target.y)
              : target;
          final range = base.extend(cell);
          final buffer = widget.terminal.buffer;
          selection.setSelection(
            buffer.createAnchorFromOffset(range.begin),
            buffer.createAnchorFromOffset(range.end),
          );
      }
    });
  }

  void _gestureMove(PointerMoveEvent event) {
    if (_gesture?.pointer != event.pointer) return;
    _selectTo(_local(event.position));
  }

  /// The pointer hovering means no button is down, so a gesture still held
  /// is one whose up never came — the window blurred mid-drag, or the
  /// platform dropped it — and [selection] would go on ignoring everything
  /// but the gesture. A drag always has its button down and never hovers.
  /// Only the device that began the gesture counts: a pen or a second mouse
  /// hovering over the pane says nothing of this one's button.
  ///
  /// This, and not a focus or an app lifecycle change, which a click itself
  /// can bring on: on a Mac the first click that activates the window did,
  /// and ended the gesture it began.
  void _gestureHover(PointerHoverEvent event) {
    if (_gesture?.device == event.device) _endGesture();
  }

  /// Gives [selection] back to xterm2 once the tap that ends the gesture has
  /// been dealt with: its tap down, which clears a selection, can come in
  /// the same dispatch as the button going up.
  void _gestureUp(PointerEvent event) {
    if (_gesture?.pointer != event.pointer) return;
    _gesture = null;
    scheduleMicrotask(() => selection.owned = false);
  }

  void _endGesture() {
    _gesture = null;
    selection.owned = false;
  }

  /// The press a program tracking drags has been sent, until its release:
  /// its pointer, -1 once released, its button, and where it last was, in
  /// the terminal's own coordinates.
  ({int pointer, TerminalMouseButton button, Offset at})? _tracked;

  void _trackedMove(PointerMoveEvent event) {
    final tracked = _tracked;
    if (tracked == null || tracked.pointer != event.pointer) return;
    _tracked = (
      pointer: tracked.pointer,
      button: tracked.button,
      at: _local(event.position),
    );
  }

  /// Whether a program has asked for the mouse's drags — button-event
  /// tracking (1002) or any-event (1003), as Claude Code's fullscreen view,
  /// vim and tmux with its mouse on do — and so gets the press, every move
  /// with the button held and the release, as xterm and iTerm2 send them:
  /// the program selects, and Claude Code copies its selection itself.
  /// xterm2 draws no selection meanwhile, and sends the moves itself.
  ///
  /// Shift keeps the drag for the terminal's own selection and copy on
  /// select, unless the program asked for Shift too; an armed Ctrl keeps it
  /// too. A desktop's mouse alone: a finger still scrolls.
  bool get _tracksDrags {
    if (!isDesktop || _ctrlArmed) return false;
    final terminal = widget.terminal;
    if (HardwareKeyboard.instance.isShiftPressed &&
        !terminal.mouseShiftCaptureMode) {
      return false;
    }
    return switch (terminal.mouseMode) {
      MouseMode.upDownScrollDrag || MouseMode.upDownScrollMove => true,
      _ => false,
    };
  }

  /// One mouse report at [global], with the keys held now. Answers whether
  /// the program reads the mouse at all.
  bool _send(
    TerminalMouseButton button,
    TerminalMouseButtonState state,
    Offset global,
  ) => _sendAt(button, state, _local(global));

  Offset _local(Offset global) =>
      _viewKey.currentState?.renderTerminal.globalToLocal(global) ?? global;

  bool _sendAt(
    TerminalMouseButton button,
    TerminalMouseButtonState state,
    Offset local,
  ) {
    final render = _viewKey.currentState?.renderTerminal;
    if (render == null) return false;
    final keys = HardwareKeyboard.instance;
    return render.mouseEvent(
      button,
      state,
      local,
      modifiers: TerminalMouseModifiers(
        shift: keys.isShiftPressed,
        alt: keys.isAltPressed,
        control: keys.isControlPressed,
      ),
    );
  }

  /// The release of a press [_mouseDown] sent, wherever the pointer went —
  /// or a cancel, which a program hears as a release too, never as a button
  /// left down.
  void _trackedUp(PointerEvent event) {
    final tracked = _tracked;
    if (tracked == null || tracked.pointer != event.pointer) return;
    _send(tracked.button, TerminalMouseButtonState.up, event.position);
    // Kept until the next press, so the tap this gesture also makes does
    // not send it again: see [_click].
    _tracked = (pointer: -1, button: tracked.button, at: tracked.at);
    selection.setPointerInputs(_pointerInputs(false));
  }

  /// A trackpad's scroll, which a Mac sends as a pan and not as a wheel,
  /// made to land where the pointer is.
  ///
  /// For a program that reads the mouse — Claude Code's fullscreen view, vim,
  /// less, a program in a tmux pane — xterm2 turns the scroll into wheel
  /// events at the cell it last saw the pointer on, and it looks for that
  /// only in a press or a wheel. A trackpad's pan is neither, so its wheel
  /// events went to wherever the last click was: after a click in Claude
  /// Code's prompt, on the prompt, which does not scroll, so scrolling did
  /// nothing until the next mouse wheel. Claude Code aims a wheel at the
  /// element under its cell, as a browser does.
  ///
  /// So the pan's start is handed on as a wheel that moves nothing, which
  /// xterm2 takes the place from and every scroll view ignores.
  // ponytail: a synthetic event, since the place is private to xterm2's
  // TerminalScrollGestureHandler; retire this once it listens to
  // onPointerPanZoomStart itself.
  void _trackpadDown(PointerPanZoomStartEvent event) {
    GestureBinding.instance.handlePointerEvent(
      PointerScrollEvent(
        viewId: event.viewId,
        timeStamp: event.timeStamp,
        kind: event.kind,
        device: event.device,
        position: event.position,
      ),
    );
  }

  /// On a desktop, what the mouse has just selected — a drag, a double
  /// click's word, a triple click's line — goes to the clipboard as the
  /// button comes up: iTerm2's habit. A program that tracks drags, Claude
  /// Code's fullscreen view among them, selects and copies for itself, and
  /// Shift+drag still selects here.
  ///
  /// Only a selection the mouse made, never one already there or one the
  /// app made. Looked at once the up has been dealt with, since xterm2
  /// selects a double click's word in the same up, after this has heard it.
  /// The text is what every other copy takes: see [selectedText].
  void _mouseUp(PointerUpEvent event) {
    _rightUp(event);
    _gestureUp(event);
    _trackedUp(event);
    if (_tracked != null) {
      // The program selects: a double or triple click's word or line, which
      // xterm2 selects whatever the program asked for, would only lie over
      // the program's own.
      scheduleMicrotask(() {
        if (mounted) selection.clearSelection();
      });
      return;
    }
    if (!isDesktop ||
        event.kind != PointerDeviceKind.mouse ||
        !copyOnSelect.value) {
      return;
    }
    final before = _selectionAtDown;
    scheduleMicrotask(() {
      final range = selection.selection;
      if (!mounted || range == null || range == before) return;
      final text = selectedText(widget.terminal.buffer, range);
      if (text.trim().isEmpty) return;
      unawaited(Clipboard.setData(ClipboardData(text: text)));
      showToast(context, 'Copied', type: TuiToastType.success);
    });
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

  /// Whether the right button's press now under way is being kept from a
  /// program that reads the mouse, and what the controller said before.
  bool? _heldRight;

  /// A desktop's right-click, where a phone would long-press, opens the
  /// pane's menu (see [_TerminalPageState._paneMenu]) whatever the program
  /// asked for, as iTerm2's does: Claude Code reads the mouse, and its users
  /// want the menu. So a plain right press is kept from the program here,
  /// before xterm2 offers it one.
  ///
  /// Shift+right-click is the program's instead, when it reads the mouse.
  /// xterm2 already keeps a shifted click from the program, so it lands here,
  /// and is handed over as the plain click it was meant to be.
  void _rightDown(PointerDownEvent event) {
    if (!isDesktop ||
        event.kind != PointerDeviceKind.mouse ||
        event.buttons != kSecondaryMouseButton ||
        HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    _heldRight ??= selection.suspendedPointerInputs;
    selection.setSuspendPointerInput(true);
  }

  /// Gives the program the mouse back once the click has gone where it was
  /// going: the tap's own callback runs as the gesture arena sweeps, after
  /// this pointer's Listeners have heard the button come up.
  void _rightUp(PointerEvent event) {
    final held = _heldRight;
    if (held == null) return;
    scheduleMicrotask(() {
      if (_heldRight == null) return;
      _heldRight = null;
      selection.setSuspendPointerInput(held);
    });
  }

  void _contextMenu(TapUpDetails details, CellOffset cell) {
    // A plain right-click; Shift+right goes to the program.
    final terminal = widget.terminal;
    if (HardwareKeyboard.instance.isShiftPressed &&
        terminal.mouseMode != MouseMode.none) {
      for (final state in [
        TerminalMouseButtonState.down,
        TerminalMouseButtonState.up,
      ]) {
        terminal.mouseInput(TerminalMouseButton.right, state, cell);
      }
      return;
    }
    widget.onContextMenu(this, details.globalPosition, cell);
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
    // The scroll is not: suspending every pointer input, as this once did,
    // took scrolling away too, and on the alternate screen or under a
    // program that reads the mouse — Claude Code, vim, less, tmux — a drag
    // is the only way a finger can scroll at all, there being no wheel. So
    // an armed CTRL froze the terminal's content until the app was killed.
    _ctrlArmed = ctrl;
    selection.setPointerInputs(_pointerInputs(_holding && !ctrl));
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

  /// What xterm2 hands a program that reads the mouse: the wheel, and the
  /// moves of a drag only while [_mouseDown] has sent its press and the
  /// release has not gone — [drag]. Never the press or the release: xterm2
  /// sends a press once the button has been down 100 ms and its release only
  /// if the gesture ends as a tap, which left a program a press that never
  /// ended. [_mouseDown] and [_click] send those instead.
  ///
  /// The moves are held to the press because xterm2 decides each one alone,
  /// from Shift and the button held then: a Shift+drag let go of Shift, a
  /// Ctrl disarmed mid-drag or a right-button drag would otherwise send a
  /// program moves with a button held that no press began and no release
  /// ends — the very drag that never ends.
  static PointerInputs _pointerInputs(bool drag) =>
      PointerInputs({PointerInput.scroll, if (drag) PointerInput.drag});

  /// Whether Ctrl has claimed the tap, for opening a link: see [showLinks].
  bool _ctrlArmed = false;

  /// A click for a program that reads the mouse — Claude Code's fullscreen
  /// view, vim, less, a program in a tmux pane — sent whole once the button
  /// is up: the press and its release together. Answers whether the program
  /// took it.
  ///
  /// xterm2 sent the press as soon as the button had been down 100 ms and
  /// the release only if the gesture ended as a tap, while a drag was its
  /// own selection. So a drag begun after a short hold left the program a
  /// press that never ended: Claude Code took it as a selection of its own
  /// being dragged, for ever, and its selection and copy broke until it next
  /// heard a release. A program that tracks drags has had this click's press
  /// and release already, from [_mouseDown]; one that does not gets no drag
  /// at all, and a click always as both halves.
  ///
  /// Shift keeps the click for the terminal, as it always has, unless the
  /// program asked for Shift too.
  bool _click(TerminalMouseButton button, Offset global) {
    if (_tracked != null) return true;
    if (_ctrlArmed && button == TerminalMouseButton.left) return false;
    final keys = HardwareKeyboard.instance;
    if (keys.isShiftPressed && !widget.terminal.mouseShiftCaptureMode) {
      return false;
    }
    if (!_send(button, TerminalMouseButtonState.down, global)) return false;
    _send(button, TerminalMouseButtonState.up, global);
    return true;
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
      onContent: _pasteContent,
      child: SwipeKeyPad(
        terminal: widget.terminal,
        controller: selection,
        onEmit: widget.onEmit,
        onPaste: _paste,
        child: Listener(
          onPointerDown: _mouseDown,
          onPointerUp: _mouseUp,
          onPointerHover: _gestureHover,
          onPointerMove: (event) {
            _trackedMove(event);
            _gestureMove(event);
          },
          onPointerCancel: (event) {
            _gestureUp(event);
            _trackedUp(event);
            _rightUp(event);
          },
          onPointerPanZoomStart: _trackpadDown,
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
            onTapUp: (details, cell) {
              _click(TerminalMouseButton.left, details.globalPosition);
              widget.onTap(this, cell);
            },
            onSecondaryTapUp: isDesktop ? _contextMenu : null,
            padding: widget.padding,
            textStyle: widget.textStyle,
            // The theme picked in Settings: a new pick repaints the shell at
            // once, with no reconnect.
            theme: terminalThemeOf(context),
          ),
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
      type: TuiToastType.warning,
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
    showToast(context, 'No app can open $url', type: TuiToastType.error);
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
                  TuiButton(
                    label: 'Close',
                    variant: TuiButtonVariant.ghost,
                    onPressed: onClose,
                  ),
                  const SizedBox(width: 8),
                ],
                TuiButton(
                  label: retryLabel ?? 'Try again',
                  prefix: '↻',
                  onPressed: onRetry,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
