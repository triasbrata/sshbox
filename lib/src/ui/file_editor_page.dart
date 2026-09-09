import 'package:flutter/material.dart';

import '../files/file_browser.dart';

/// Opens one remote file for reading and, if you want, changing.
///
/// Pops `true` when something was actually saved, so the listing behind it
/// knows to reload the size and timestamp it is showing.
class FileEditorPage extends StatefulWidget {
  const FileEditorPage({
    super.key,
    required this.browser,
    required this.path,
  });

  final FileBrowser browser;
  final String path;

  @override
  State<FileEditorPage> createState() => _FileEditorPageState();
}

class _FileEditorPageState extends State<FileEditorPage> {
  final _controller = TextEditingController();

  /// What is on the host, as far as we know. Compared against the field to
  /// decide whether there is anything to save — a user who types a character
  /// and deletes it again has not made a change.
  String _original = '';

  String? _error;
  FileBrowserFault? _fault;
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;

  bool get _dirty => _controller.text != _original;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onEdited);
    _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onEdited);
    _controller.dispose();
    super.dispose();
  }

  /// Only the save button's enabled state depends on this, but that state
  /// changes on the first and last keystroke of an edit, so it has to be
  /// watched rather than sampled.
  void _onEdited() {
    setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _fault = null;
    });

    try {
      final text = await widget.browser.readText(widget.path);
      if (!mounted) return;
      setState(() {
        _original = text;
        _controller.text = text;
        _loading = false;
      });
    } on FileBrowserException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _fault = error.fault;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final text = _controller.text;

    try {
      await widget.browser.writeText(widget.path, text);
      if (!mounted) return;
      setState(() {
        // Not `_controller.text`: the user may have typed while the write was
        // in flight, and those keystrokes are genuinely still unsaved.
        _original = text;
        _saved = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${RemotePath.basename(widget.path)}')),
      );
    } on FileBrowserException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: Text(
          'Your edits to ${RemotePath.basename(widget.path)} have not been '
          'saved to the host.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop(_saved);
  }

  @override
  Widget build(BuildContext context) {
    final canSave = !_loading && _error == null && _dirty && !_saving;

    return PopScope<bool>(
      // An unsaved edit on a phone is one stray back-swipe from being gone,
      // and there is no undo on the far end.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () =>
                _dirty ? _confirmDiscard() : Navigator.of(context).pop(_saved),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                RemotePath.basename(widget.path),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _dirty ? 'Unsaved changes' : RemotePath.parent(widget.path),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          bottom: _saving
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(3),
                  child: LinearProgressIndicator(),
                )
              : null,
          actions: [
            IconButton(
              tooltip: 'Reload from host',
              onPressed: _loading || _saving ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'Save to host',
              onPressed: canSave ? _save : null,
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final error = _error;
    if (error != null) return _EditorError(message: error, fault: _fault);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: TextField(
        controller: _controller,
        // Files are code and config far more often than prose, and both are
        // unreadable in a proportional face once alignment matters.
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        // Every one of these fights a plain text file: autocorrect rewrites
        // identifiers, and capitalisation breaks case-sensitive keys.
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.none,
        decoration: const InputDecoration(border: InputBorder.none),
      ),
    );
  }
}

class _EditorError extends StatelessWidget {
  const _EditorError({required this.message, this.fault});

  final String message;
  final FileBrowserFault? fault;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (fault) {
      FileBrowserFault.tooLarge => Icons.straighten,
      FileBrowserFault.notText => Icons.data_object,
      FileBrowserFault.permissionDenied => Icons.lock_outline,
      _ => Icons.error_outline,
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
