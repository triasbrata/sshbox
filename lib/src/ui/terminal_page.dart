import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm2/xterm.dart';

import '../data/secret_store.dart';
import '../files/file_browser.dart';
import '../session/session_manager.dart';
import 'file_browser_page.dart';
import 'key_bar.dart';
import 'magic_key.dart';
import 'terminal_link.dart';
import 'terminal_text_input.dart';

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

  /// Shared with the terminal view below it, which is what holds focus.
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final _inputKey = GlobalKey<TerminalTextInputState>();

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

  LiveSession get _session => widget.session;

  /// Forwards and problems already announced, so each gets one snack bar.
  /// Held by identity: a server that restarts is a new forward, and says so.
  final _announced = <Object>{};

  @override
  void initState() {
    super.initState();

    // Only meaningful while this page is on screen, so it is installed and
    // removed with the widget rather than held by the session.
    _session.outputTransform = _keyBar.applyModifiers;
    _session.addListener(_onSessionChanged);

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
    }
    setState(() {});
    _announceForwards();
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
                  onPressed: () => _openForward(address),
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

  void _openForward(String address) => launchUrl(
        Uri.parse('http://$address'),
        mode: LaunchMode.externalApplication,
      );

  /// The session menu's tail: what this session has on the tailnet, each
  /// opening in the browser.
  List<PopupMenuEntry<String>> _forwardItems() {
    final forwarder = _session.forwarder;
    final problem = forwarder.problem;
    if (!_session.isConnected ||
        (forwarder.forwards.isEmpty && problem == null)) {
      return const [];
    }
    PopupMenuItem<String> item(String text, {String? address}) =>
        PopupMenuItem(
          enabled: address != null,
          onTap: address == null ? null : () => _openForward(address),
          child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
        );
    return [
      const PopupMenuDivider(),
      for (final forward in forwarder.forwards)
        item(
          '${forward.port} → '
          '${forward.address ?? forward.error ?? 'starting…'}',
          address: forward.address,
        ),
      if (problem != null) item('Not forwarding ports: $problem'),
    ];
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
    _focusNode.dispose();
    _scrollController.dispose();
    if (_session.outputTransform == _keyBar.applyModifiers) {
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

  /// Typing anywhere in the scrollback should snap back to the prompt.
  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    position.jumpTo(position.maxScrollExtent);
  }

  void _reportPinnedKey(String fingerprint) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('Pinned new host key\n$fingerprint'),
      ),
    );
  }

  Future<void> _reconnect() => _session.reconnect(
        secrets: widget.secrets,
        onHostKeyPinned: _reportPinnedKey,
      );

  // Leaves the tab open on a closed session: the scrollback is still worth
  // reading, and reconnecting is one button away. Closing the tab is what
  // throws the session away.
  Future<void> _disconnect() => _session.disconnect();

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
        ownsBrowser: false,
        onRootChanged: (root) => _browseRoot = root,
        onExpandedChanged: (expanded) => _browseExpanded = expanded,
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

  /// Sends the shell to a directory.
  ///
  /// The newline is what separates this from [_typePath]: it runs something.
  /// That is why the browser only does it when told to, never as a side effect
  /// of tapping a folder.
  void _cdTo(String path) => _session.sendRaw('cd ${_shellQuote(path)}\n');

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
      appBar: AppBar(
        title: Text(_session.title, overflow: TextOverflow.ellipsis),
        bottom: _uploading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(value: _uploadProgress),
              )
            : null,
        actions: [
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
          // The rest live in a menu: four icons plus a title do not fit across
          // a phone, and these are the three used least often.
          PopupMenuButton<String>(
            tooltip: 'Session',
            onSelected: (choice) {
              switch (choice) {
                case 'reconnect':
                  _reconnect();
                case 'disconnect':
                  _disconnect();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'reconnect',
                enabled: !_session.connecting,
                child: const Text('Reconnect'),
              ),
              PopupMenuItem(
                value: 'disconnect',
                enabled: _session.isConnected,
                child: const Text('Disconnect'),
              ),
              ..._forwardItems(),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      // In the Scaffold's own slot rather than the body so it rides above the
      // soft keyboard and the button below floats clear of it.
      bottomNavigationBar: _session.isConnected
          ? TerminalKeyBar(
              controller: _keyBar,
              terminal: _session.terminal,
              onEmit: _session.sendRaw,
            )
          : null,
    );
  }

  Widget _buildBody() {
    final error = _session.error;
    if (error != null && !_session.isConnected) {
      return _ConnectionError(message: error, onRetry: _reconnect);
    }

    return Stack(
      children: [
        // Two wrappers, because they take different things: the input owns
        // the keyboard connection, the pad owns the swipe. The pad sits
        // inside so its gestures land on the terminal itself — it claims
        // only pans and double taps, so a plain tap still falls through to
        // xterm2 below and asks for the keyboard back.
        TerminalTextInput(
          key: _inputKey,
          terminal: _session.terminal,
          focusNode: _focusNode,
          onInput: _scrollToBottom,
          child: SwipeKeyPad(
            terminal: _session.terminal,
            onEmit: _session.sendRaw,
            child: TerminalView(
              _session.terminal,
              focusNode: _focusNode,
              scrollController: _scrollController,
              autofocus: true,
              // The soft keyboard belongs to TerminalTextInput; xterm2 keeps
              // hardware keys, shortcuts and selection gestures.
              hardwareKeyboardOnly: true,
              // Tapping a terminal that already has focus is how you ask for
              // the keyboard back, and focus alone will not raise it.
              onTapUp: (_, _) => _inputKey.currentState?.requestKeyboard(),
              padding: const EdgeInsets.all(6),
              textStyle: const TerminalStyle(fontSize: 13),
            ),
          ),
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
        // In the body rather than the Scaffold's button slot so it can be
        // parked anywhere, and so its ring is free to open over the terminal.
        if (_session.isConnected)
          Positioned.fill(
            child: MagicKey(
              terminal: _session.terminal,
              onEmit: _session.sendRaw,
            ),
          ),
      ],
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
            onPressed: () => launchUrl(url, mode: LaunchMode.externalApplication),
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
