import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    this.onClose,
    this.draftKey,
  });

  final FileBrowser browser;
  final String path;

  /// Dismisses the editor when it is a pane rather than a screen.
  ///
  /// Null on a phone, where leaving means popping this route. Set on a tablet,
  /// where the editor sits beside the terminal and closing it just gives the
  /// terminal the width back.
  final VoidCallback? onClose;

  /// Names this file across app restarts, so an unsaved edit can be kept on
  /// the phone and offered back after Android kills the app in the background.
  /// Null keeps no draft.
  final String? draftKey;

  @override
  State<FileEditorPage> createState() => _FileEditorPageState();
}

enum _Conflict { overwrite, reload }

/// ponytail: prefs rewrite their whole store on every write, so drafts of big
/// files are skipped. Move drafts to files if losing those starts to matter.
const _draftLimit = 256 * 1024;

String _draftPrefsKey(String key) => 'editor.draft.$key';

class _FileEditorPageState extends State<FileEditorPage> {
  final _controller = TextEditingController();

  /// What is on the host, as far as we know. Compared against the field to
  /// decide whether there is anything to save — a user who types a character
  /// and deletes it again has not made a change.
  String _original = '';

  /// The version of the file [_original] came from. A save that finds
  /// anything else on the host stops and asks instead of writing over it.
  FileStamp? _stamp;

  /// A draft from an earlier run, waiting on the banner to restore or drop it.
  RemoteText? _draft;

  Timer? _draftTimer;

  /// Set once the user has chosen to throw the edit away, so the flush on the
  /// way out does not store it again.
  bool _dropDraft = false;

  String? _error;
  FileBrowserFault? _fault;
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;

  bool get _dirty => _controller.text != _original;

  bool get _embedded => widget.onClose != null;

  /// Leaves the editor: closes the pane when embedded, pops the route when it
  /// is one. Everywhere that gives up on the file goes through here.
  void _leave() {
    final close = widget.onClose;
    if (close != null) {
      close();
      return;
    }
    Navigator.of(context).pop(_saved);
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onEdited);
    _load();
  }

  @override
  void dispose() {
    // Flushed rather than dropped: closing a session takes its file tabs down
    // without asking, and this is all that is left of the edit.
    if (_draftTimer?.isActive ?? false) {
      _draftTimer!.cancel();
      unawaited(_storeDraft());
    }
    _controller.removeListener(_onEdited);
    _controller.dispose();
    super.dispose();
  }

  /// Only the save button's enabled state depends on this, but that state
  /// changes on the first and last keystroke of an edit, so it has to be
  /// watched rather than sampled.
  void _onEdited() {
    setState(() {});
    if (widget.draftKey == null) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(seconds: 2), _storeDraft);
  }

  Future<void> _storeDraft() async {
    final key = widget.draftKey;
    // A draft still waiting on the banner is not this edit's to overwrite.
    if (key == null || _draft != null || _dropDraft) return;
    // Read before the first await: on the way out the field is disposed next.
    final text = _controller.text;
    final stamp = _stamp;
    final dirty = text != _original;

    final prefs = await SharedPreferences.getInstance();
    if (!dirty) {
      await prefs.remove(_draftPrefsKey(key));
      return;
    }
    if (text.length > _draftLimit) return;
    await prefs.setString(
      _draftPrefsKey(key),
      jsonEncode({
        'text': text,
        'modified': stamp?.modified?.millisecondsSinceEpoch,
        'size': stamp?.size,
      }),
    );
  }

  Future<RemoteText?> _readDraft() async {
    final key = widget.draftKey;
    if (key == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_draftPrefsKey(key));
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final modified = json['modified'] as int?;
    return (
      text: json['text'] as String,
      stamp: (
        modified: modified == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(modified),
        size: json['size'] as int?,
      ),
    );
  }

  Future<void> _clearDraft() async {
    final key = widget.draftKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftPrefsKey(key));
  }

  void _restoreDraft() {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _draft = null;
      // The draft was made against this version. If the host has moved on
      // since, saving raises the same question any other conflicting save
      // does, rather than quietly writing over the newer file.
      _stamp = draft.stamp;
      _controller.text = draft.text;
    });
  }

  void _discardStoredDraft() {
    setState(() => _draft = null);
    unawaited(_clearDraft());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _fault = null;
    });

    try {
      final read = await widget.browser.readText(widget.path);
      final draft = await _readDraft();
      if (!mounted) return;
      setState(() {
        _original = read.text;
        _stamp = read.stamp;
        _controller.text = read.text;
        _loading = false;
        // A draft that matches the host has nothing left to offer.
        _draft = draft != null && draft.text != read.text ? draft : null;
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

  Future<void> _reload() async {
    if (_dirty && !await _confirmDiscard()) return;
    await _load();
  }

  /// [overwrite] skips the check that the host still has the version this
  /// edit started from — only ever set once the user has said so.
  Future<void> _save({bool overwrite = false}) async {
    setState(() => _saving = true);
    final text = _controller.text;
    var conflict = false;

    try {
      final stamp = await widget.browser.writeText(
        widget.path,
        text,
        expected: overwrite ? null : _stamp,
      );
      if (!mounted) return;
      setState(() {
        // Not `_controller.text`: the user may have typed while the write was
        // in flight, and those keystrokes are genuinely still unsaved.
        _original = text;
        _stamp = stamp;
        _saved = true;
      });
      if (!_dirty) unawaited(_clearDraft());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${RemotePath.basename(widget.path)}')),
      );
    } on FileBrowserException catch (error) {
      if (!mounted) return;
      if (error.fault == FileBrowserFault.changed) {
        conflict = true;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }

    if (conflict && mounted) await _resolveConflict();
  }

  Future<void> _resolveConflict() async {
    final choice = await showDialog<_Conflict>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Changed on the host'),
        content: Text(
          '${RemotePath.basename(widget.path)} was saved on the host after you '
          'opened it. Overwrite that version with yours, or reload it and drop '
          'your edits?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_Conflict.reload),
            child: const Text('Reload'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_Conflict.overwrite),
            child: const Text('Overwrite'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _Conflict.overwrite:
        await _save(overwrite: true);
      case _Conflict.reload:
        await _load();
      case null:
        break;
    }
  }

  Future<bool> _confirmDiscard() async {
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
    return discard == true && mounted;
  }

  Future<void> _leaveIfConfirmed() async {
    if (_dirty) {
      if (!await _confirmDiscard()) return;
      _dropDraft = true;
      unawaited(_clearDraft());
    }
    _leave();
  }

  @override
  Widget build(BuildContext context) {
    final canSave = !_loading && _error == null && _dirty && !_saving;

    return PopScope<bool>(
      // An unsaved edit on a phone is one stray back-swipe from being gone,
      // and there is no undo on the far end. Embedded, back always has work to
      // do here first: close the pane rather than leave the terminal behind it.
      canPop: !_embedded && !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveIfConfirmed();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(
            tooltip: _embedded ? 'Close file' : 'Back',
            icon: Icon(_embedded ? Icons.close : Icons.arrow_back),
            onPressed: _leaveIfConfirmed,
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
              onPressed: _loading || _saving ? null : _reload,
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

    return Column(
      children: [
        if (_draft != null)
          MaterialBanner(
            content: const Text(
              'There are unsaved edits to this file from last time.',
            ),
            actions: [
              TextButton(
                onPressed: _discardStoredDraft,
                child: const Text('Discard'),
              ),
              TextButton(
                onPressed: _restoreDraft,
                child: const Text('Restore'),
              ),
            ],
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: TextField(
              controller: _controller,
              // Files are code and config far more often than prose, and both
              // are unreadable in a proportional face once alignment matters.
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              // Every one of these fights a plain text file: autocorrect
              // rewrites identifiers, and capitalisation breaks case-sensitive
              // keys.
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(border: InputBorder.none),
            ),
          ),
        ),
      ],
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
