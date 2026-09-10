import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm2/xterm.dart';

import '../data/secret_store.dart';
import '../session/session_manager.dart';
import 'files_page.dart';
import 'key_bar.dart';
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
  });

  final LiveSession session;
  final SecretStore secrets;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _keyBar = KeyBarController();

  /// Shared with the terminal view below it, which is what holds focus.
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final _inputKey = GlobalKey<TerminalTextInputState>();

  bool _uploading = false;
  double? _uploadProgress;

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
    });
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
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

  /// Opens code-server through a tunnel over this session.
  Future<void> _openFiles() async {
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
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _uploading = true);

    try {
      final remotePath = await _session.uploadToTmp(
        localPath: localPath,
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
            onPressed: (_session.isConnected && _session.canForwardPorts)
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
          IconButton(
            tooltip: 'Reconnect',
            onPressed: _session.connecting ? null : _reconnect,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Disconnect',
            onPressed: _session.isConnected ? _disconnect : null,
            icon: const Icon(Icons.link_off),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
          if (_session.isConnected)
            TerminalKeyBar(
              controller: _keyBar,
              terminal: _session.terminal,
              onEmit: _session.sendRaw,
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

    return Stack(
      children: [
        TerminalTextInput(
          key: _inputKey,
          terminal: _session.terminal,
          focusNode: _focusNode,
          onInput: _scrollToBottom,
          child: TerminalView(
            _session.terminal,
            focusNode: _focusNode,
            scrollController: _scrollController,
            autofocus: true,
            // The soft keyboard belongs to TerminalTextInput; xterm2 keeps
            // hardware keys, shortcuts and selection gestures.
            hardwareKeyboardOnly: true,
            // Tapping a terminal that already has focus is how you ask for the
            // keyboard back, and focus alone will not raise it.
            onTapUp: (_, _) => _inputKey.currentState?.requestKeyboard(),
            padding: const EdgeInsets.all(6),
            textStyle: const TerminalStyle(fontSize: 13),
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
