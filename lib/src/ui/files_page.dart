import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../session/session_manager.dart';
import '../session/terminal_session.dart';

/// Shows code-server running on the remote host.
///
/// code-server is a web application, not a file API, so the way to use it is
/// to display it. It stays bound to loopback on the server and is reached
/// through a port forward over the session that is already authenticated —
/// nothing is exposed to the network, and there is no second connection.
class FilesPage extends StatefulWidget {
  const FilesPage({
    super.key,
    required this.session,
    this.remotePort = 8080,
  });

  final LiveSession session;

  /// Where code-server listens on the remote host.
  final int remotePort;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  LocalPortForward? _forward;
  WebViewController? _controller;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final forward = await widget.session.forwardLocalPort(
        // Loopback *on the server* — this is resolved at the far end of the
        // tunnel, not on the phone.
        remoteHost: '127.0.0.1',
        remotePort: widget.remotePort,
      );

      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..loadRequest(Uri.parse('http://127.0.0.1:${forward.localPort}/'));

      if (!mounted) {
        await forward.close();
        return;
      }

      setState(() {
        _forward = forward;
        _controller = controller;
        _loading = false;
      });
    } on SshSessionException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    // Tearing the tunnel down with the page keeps a listener from lingering on
    // the device after the user has moved on.
    _forward?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            onPressed: _loading ? null : () => _controller?.reload(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final error = _error;
    if (error != null) {
      return _FilesError(message: error, onRetry: _open);
    }

    final controller = _controller;
    if (_loading || controller == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return WebViewWidget(controller: controller);
  }
}

class _FilesError extends StatelessWidget {
  const _FilesError({required this.message, required this.onRetry});

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
            Icon(Icons.folder_off_outlined,
                size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'Is code-server running on the host?\n'
              'Start it with: code-server ~/dev',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
