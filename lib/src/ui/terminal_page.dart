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
import 'file_editor_page.dart';
import 'files_page.dart';
import 'key_bar.dart';
import 'terminal_link.dart';
import 'terminal_text_input.dart';
import 'workbench.dart';

/// Shows a [LiveSession]. Deliberately owns nothing that must survive
/// navigation — the terminal, its scrollback and the SSH connection all belong
/// to the session, so leaving this page keeps them alive and coming back
/// re-attaches to the same shell.
class TerminalPage extends StatefulWidget {
  const TerminalPage({
    super.key,
    required this.session,
    required this.secrets,
  });

  final LiveSession session;
  final SecretStore secrets;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

/// Material's "expanded" breakpoint.
///
/// Below it a split leaves both halves too narrow to work in: a phone in
/// landscape is 800dp and stays one pane, which is the right answer for it.
const double _tabletWidth = 840;

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

  /// The file showing beside the terminal, if any. Null means the terminal has
  /// the whole width, which is how a session starts.
  String? _openFile;

  /// Where the drawer was last looking, so reopening it does not throw the
  /// user back to their home directory.
  String? _browsePath;

  LiveSession get _session => widget.session;

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
      _openFile = null;
      _browsePath = null;
    }
    setState(() {});
    // A file shared from another app may have been queued before this page
    // existed, or before the shell came up. Either way the session notifies,
    // and this is where it lands.
    unawaited(_drainShared());
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

  Future<void> _disconnect() async {
    await _session.disconnect();
    if (mounted) Navigator.of(context).maybePop();
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
        initialPath: _browsePath,
        ownsBrowser: false,
        onPathChanged: (path) => _browsePath = path,
        terminal: _terminalLink,
        onClose: _closeFilesDrawer,
        onFileSelected: _openFileBeside,
      ),
    );
  }

  void _closeFilesDrawer() => _scaffoldKey.currentState?.closeEndDrawer();

  /// Opens [path]: beside the terminal where there is room for both, and as a
  /// screen of its own where there is not.
  Future<void> _openFileBeside(String path) async {
    _closeFilesDrawer();
    final browser = _browser;
    if (browser == null) return;

    if (MediaQuery.sizeOf(context).width >= _tabletWidth) {
      setState(() => _openFile = path);
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileEditorPage(browser: browser, path: path),
      ),
    );
  }

  Widget _buildWorkbench(bool wide) {
    final openFile = _openFile;
    final browser = _browser;
    final showEditor = wide && openFile != null && browser != null;

    return Workbench(
      primary: _buildBody(),
      secondary: !showEditor
          ? null
          : FileEditorPage(
              // Keyed on the path, so picking a second file loads it instead
              // of leaving the first one's text sitting in the field.
              key: ValueKey(openFile),
              browser: browser,
              path: openFile,
              onClose: () => setState(() => _openFile = null),
            ),
    );
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

  /// Opens code-server through a tunnel over this session.
  ///
  /// Kept alongside the native browser rather than replaced by it: this is a
  /// full editor with a language server behind it, which is a different thing
  /// from reading a config file on a phone.
  Future<void> _openCodeServer() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => FilesPage(session: _session)),
    );
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
    final wide = MediaQuery.sizeOf(context).width >= _tabletWidth;

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
                case 'code-server':
                  _openCodeServer();
                case 'reconnect':
                  _reconnect();
                case 'disconnect':
                  _disconnect();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'code-server',
                enabled: _session.isConnected && _session.canForwardPorts,
                child: const Text('Open code-server'),
              ),
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
            ],
          ),
        ],
      ),
      body: _buildWorkbench(wide),
      // In the Scaffold's own slot rather than the body so it rides above the
      // soft keyboard and the button below floats clear of it.
      bottomNavigationBar: _session.isConnected
          ? TerminalKeyBar(
              controller: _keyBar,
              terminal: _session.terminal,
              onEmit: _session.sendRaw,
            )
          : null,
      // Enter is the one key you reach for with the keyboard down — reading
      // output, answering a prompt, waking a dozing shell. ExcludeFocus keeps
      // the tap from pulling focus off the terminal, which would close the
      // keyboard for anyone who did have it open.
      floatingActionButton: _session.isConnected
          ? ExcludeFocus(
              child: FloatingActionButton.small(
                // Not just "Enter": the soft keyboard puts a key of that name
                // in the accessibility tree too, and a test reaching for this
                // button finds that one first.
                tooltip: 'Send Enter',
                onPressed: () => _session.sendRaw('\r'),
                child: const Icon(Icons.keyboard_return),
              ),
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
