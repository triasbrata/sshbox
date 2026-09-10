import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../session/session_manager.dart';
import '../session/terminal_session.dart';

/// Shows one remote file, read over the session it was picked from.
///
/// Read-only on purpose: editing on a phone is what the shell in the next tab
/// is for. This is for looking — a config, a log tail, what a script actually
/// says before you run it.
class FilePage extends StatefulWidget {
  const FilePage({
    super.key,
    required this.session,
    required this.path,
  });

  final LiveSession session;

  /// Absolute path on the remote host.
  final String path;

  /// How much of a file is worth pulling onto a phone. A log can be gigabytes;
  /// this is enough to read and small enough to hold.
  static const int maxBytes = 512 * 1024;

  /// Binary content read as text is noise at best, so it is not shown at all.
  /// A NUL byte is the same signal `grep` and `file` use.
  static bool looksBinary(Uint8List bytes) => bytes.contains(0);

  @override
  State<FilePage> createState() => _FilePageState();
}

class _FilePageState extends State<FilePage> {
  String? _text;
  String? _error;
  bool _binary = false;
  bool _truncated = false;
  bool _loading = true;

  String get _name => widget.path.split('/').last;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final bytes = await widget.session.readFile(
        widget.path,
        maxBytes: FilePage.maxBytes,
      );
      if (!mounted) return;

      // The transport reads one byte past the cap, so more than the cap means
      // there is more file behind what we are showing.
      final truncated = bytes.length > FilePage.maxBytes;
      final shown = truncated
          ? Uint8List.sublistView(bytes, 0, FilePage.maxBytes)
          : bytes;

      setState(() {
        _binary = FilePage.looksBinary(shown);
        _truncated = truncated;
        _text = _binary ? null : const Utf8Decoder(allowMalformed: true).convert(shown);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is SshSessionException ? error.message : error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _copy() async {
    final text = _text;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('File copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_name, overflow: TextOverflow.ellipsis),
        bottom: _truncated
            ? PreferredSize(
                preferredSize: const Size.fromHeight(24),
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Showing the first '
                      '${FilePage.maxBytes ~/ 1024} KB',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
              )
            : null,
        actions: [
          IconButton(
            tooltip: 'Copy',
            onPressed: _text == null ? null : _copy,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Reload file',
            onPressed: _loading ? null : _read,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);

    if (_loading) return const Center(child: CircularProgressIndicator());

    final error = _error;
    if (error != null) {
      return _Notice(
        icon: Icons.error_outline,
        color: theme.colorScheme.error,
        message: error,
        onRetry: _read,
      );
    }

    if (_binary) {
      return _Notice(
        icon: Icons.data_object,
        color: theme.colorScheme.onSurfaceVariant,
        message: 'This looks like a binary file, so there is nothing to read '
            'here. Use the shell tab if you need it.',
      );
    }

    // Code and logs are written in lines that do not wrap, so the horizontal
    // scroll is what keeps them readable rather than reflowed into soup.
    return SingleChildScrollView(
      primary: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            _text ?? '',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final Color color;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: color),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
