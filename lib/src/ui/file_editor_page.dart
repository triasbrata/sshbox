import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../files/file_browser.dart';
import 'code_languages.dart';

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

const _prefsFontSize = 'editor.fontSize';
const _prefsWordWrap = 'editor.wordWrap';

class _FileEditorPageState extends State<FileEditorPage> {
  final _controller = CodeLineEditingController();

  late final _codeTheme = codeThemeFor(widget.path);

  late final _toolbar = MobileSelectionToolbarController(
    builder: _selectionMenu,
  );

  /// What is on the host, as far as we know, in the editor's own `\n` form.
  /// Compared against the field to decide whether there is anything to save —
  /// a user who types a character and deletes it again has not made a change.
  String _original = '';

  /// The line break the file on the host uses. The editor works in `\n`
  /// throughout, since re_editor splits on any break and joins on one, and the
  /// file's own goes back in on save: a CRLF file stays CRLF, rather than
  /// reading as changed from the first frame and being saved as LF.
  String _lineBreak = '\n';

  bool _dirty = false;

  double _fontSize = 13;

  /// On by default, as the plain field it replaced always wrapped: a long
  /// line on a phone is otherwise a long way off to the right.
  bool _wordWrap = true;

  /// The version of the file [_original] came from. A save that finds
  /// anything else on the host stops and asks instead of writing over it.
  FileStamp? _stamp;

  /// A draft from an earlier run, waiting on the banner to restore or drop it.
  RemoteText? _draft;

  Timer? _draftTimer;

  /// Set once the user has chosen to throw the edit away, so the flush on the
  /// way out does not store it again.
  bool _dropDraft = false;

  /// Whether the file was last read or saved through sudo. Reloads and saves
  /// keep going that way until the editor closes.
  bool _asRoot = false;

  /// What sudo was last given and took. Held only here, never stored, and
  /// gone with the editor.
  String? _sudoPassword;

  SudoCapable? get _sudo => switch (widget.browser) {
        final SudoCapable sudo => sudo,
        _ => null,
      };

  String? _error;
  FileBrowserFault? _fault;
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;

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
    unawaited(_restoreLook());
    _load();
  }

  Future<void> _restoreLook() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _fontSize = prefs.getDouble(_prefsFontSize) ?? _fontSize;
      _wordWrap = prefs.getBool(_prefsWordWrap) ?? _wordWrap;
    });
  }

  Future<void> _setLook({double? fontSize, bool? wordWrap}) async {
    setState(() {
      if (fontSize != null) _fontSize = fontSize.clamp(9, 24).toDouble();
      if (wordWrap != null) _wordWrap = wordWrap;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsFontSize, _fontSize);
    await prefs.setBool(_prefsWordWrap, _wordWrap);
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

  /// The controller reports every caret move as well as every edit, so the
  /// page is rebuilt only when that flips whether there is anything to save.
  ///
  /// ponytail: `text` joins every line on each report, O(n) a keystroke;
  /// fine up to the 1 MiB read limit. Compare `codeLines` if it starts to lag.
  void _onEdited() {
    final dirty = _controller.text != _original;
    if (dirty != _dirty) setState(() => _dirty = dirty);
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

  /// [root] reads through sudo. Left out, the file is read the way it was
  /// last read.
  Future<void> _load({bool? root}) async {
    final asRoot = root ?? _asRoot;
    setState(() {
      _loading = true;
      _error = null;
      _fault = null;
    });

    try {
      final read = await _read(root: asRoot);
      final draft = await _readDraft();
      if (!mounted) return;
      final text = read.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      setState(() {
        _lineBreak = read.text.contains('\r\n')
            ? '\r\n'
            : read.text.contains('\r')
                ? '\r'
                : '\n';
        _original = text;
        _stamp = read.stamp;
        _controller.text = text;
        // Undo stops at the file as it came, not at the empty page before it.
        _controller.clearHistory();
        _dirty = false;
        _loading = false;
        _asRoot = asRoot;
        // A draft that matches the host has nothing left to offer.
        _draft = draft != null && draft.text != text ? draft : null;
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

  Future<RemoteText> _read({required bool root}) async {
    final sudo = _sudo;
    if (!root || sudo == null) return widget.browser.readText(widget.path);
    final read = await _asRootWith(
      (password) => sudo.sudoReadText(widget.path, password: password),
    );
    return read ??
        (throw const FileBrowserException(
          'sudo needs your password to open this file.',
          fault: FileBrowserFault.permissionDenied,
        ));
  }

  /// Null when sudo wanted a password and the user would not give one.
  Future<FileStamp?> _write(
    String text, {
    required bool root,
    required bool overwrite,
  }) {
    final expected = overwrite ? null : _stamp;
    final sudo = _sudo;
    if (!root || sudo == null) {
      return widget.browser.writeText(widget.path, text, expected: expected);
    }
    return _asRootWith(
      (password) => sudo.sudoWriteText(
        widget.path,
        text,
        password: password,
        expected: expected,
      ),
    );
  }

  /// Runs [attempt] through sudo: with the password already given here, else
  /// first without one (a sudo that does not ask needs none) and then with
  /// one the user types. Null when they would not give one.
  Future<T?> _asRootWith<T>(
    Future<T> Function(String? password) attempt,
  ) async {
    final known = _sudoPassword;
    try {
      return await attempt(known);
    } on FileBrowserException catch (error) {
      if (error.fault != FileBrowserFault.permissionDenied) rethrow;
      // A password that stopped working is asked for afresh next time.
      if (known != null) {
        _sudoPassword = null;
        rethrow;
      }
    }
    if (!mounted) return null;
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordPrompt(),
    );
    if (password == null || !mounted) return null;
    final result = await attempt(password);
    _sudoPassword = password;
    return result;
  }

  Future<void> _reload() async {
    if (_dirty && !await _confirmDiscard()) return;
    await _load();
  }

  /// [overwrite] skips the check that the host still has the version this
  /// edit started from — only ever set once the user has said so. [root]
  /// saves through sudo; left out, the file is saved the way it was read.
  Future<void> _save({bool overwrite = false, bool? root}) async {
    final asRoot = root ?? _asRoot;
    setState(() => _saving = true);
    final text = _controller.text;
    var conflict = false;

    try {
      final stamp = await _write(
        _lineBreak == '\n' ? text : text.replaceAll('\n', _lineBreak),
        root: asRoot,
        overwrite: overwrite,
      );
      if (stamp == null || !mounted) return;
      setState(() {
        // Not `_controller.text`: the user may have typed while the write was
        // in flight, and those keystrokes are genuinely still unsaved.
        _original = text;
        _dirty = _controller.text != text;
        _stamp = stamp;
        _saved = true;
        _asRoot = asRoot;
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
        // Readable but not writable, like /etc/hosts: saving as root is the
        // one way left to get the edit onto the host.
        final offerSudo = error.fault == FileBrowserFault.permissionDenied &&
            !asRoot &&
            _sudo != null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.message),
            action: offerSudo
                ? SnackBarAction(
                    label: 'Save with sudo',
                    onPressed: () {
                      if (mounted) _save(root: true);
                    },
                  )
                : null,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }

    if (conflict && mounted) await _resolveConflict(root: asRoot);
  }

  Future<void> _resolveConflict({required bool root}) async {
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
        await _save(overwrite: true, root: root);
      case _Conflict.reload:
        await _load(root: root);
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
                [
                  if (_asRoot) 'as root',
                  _dirty ? 'Unsaved changes' : RemotePath.parent(widget.path),
                ].join(' · '),
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
            PopupMenuButton<VoidCallback>(
              tooltip: 'View',
              onSelected: (action) => action(),
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: () => _setLook(wordWrap: !_wordWrap),
                  checked: _wordWrap,
                  child: const Text('Word wrap'),
                ),
                PopupMenuItem(
                  value: () => _setLook(fontSize: _fontSize + 1),
                  child: const Text('Larger text'),
                ),
                PopupMenuItem(
                  value: () => _setLook(fontSize: _fontSize - 1),
                  child: const Text('Smaller text'),
                ),
              ],
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
    if (error != null) {
      return _EditorError(
        message: error,
        fault: _fault,
        onSudo: _fault == FileBrowserFault.permissionDenied && _sudo != null
            ? () => _load(root: true)
            : null,
      );
    }

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
          // re_editor opens the keyboard with autocorrect, smart punctuation
          // and capitalisation all off, as a plain text file needs.
          child: CodeEditor(
            controller: _controller,
            wordWrap: _wordWrap,
            toolbarController: _toolbar,
            style: CodeEditorStyle(
              fontSize: _fontSize,
              // Files are code and config far more often than prose, and both
              // are unreadable in a proportional face once alignment matters.
              fontFamily: 'monospace',
              codeTheme: _codeTheme,
            ),
            indicatorBuilder: (context, editing, chunks, notifier) =>
                DefaultCodeLineNumber(controller: editing, notifier: notifier),
          ),
        ),
      ],
    );
  }

  /// The menu over a selection on a touch screen, drawn the way the platform
  /// draws it for any other text field.
  Widget _selectionMenu({
    required BuildContext context,
    required TextSelectionToolbarAnchors anchors,
    required CodeLineEditingController controller,
    required VoidCallback onDismiss,
    required VoidCallback onRefresh,
  }) {
    final selected = !controller.selection.isCollapsed;
    ContextMenuButtonItem item(ContextMenuButtonType type, VoidCallback run) =>
        ContextMenuButtonItem(
          type: type,
          onPressed: () {
            run();
            onDismiss();
          },
        );

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: [
        if (selected) item(ContextMenuButtonType.cut, controller.cut),
        if (selected) item(ContextMenuButtonType.copy, controller.copy),
        item(ContextMenuButtonType.paste, controller.paste),
        if (!controller.isAllSelected)
          ContextMenuButtonItem(
            type: ContextMenuButtonType.selectAll,
            onPressed: () {
              controller.selectAll();
              // Stays up over the new selection, ready to copy it.
              onRefresh();
            },
          ),
      ],
    );
  }
}

class _EditorError extends StatelessWidget {
  const _EditorError({required this.message, this.fault, this.onSudo});

  final String message;
  final FileBrowserFault? fault;

  /// Set when the login was refused and sudo might still get the file open.
  final VoidCallback? onSudo;

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
            if (onSudo != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onSudo,
                icon: const Icon(Icons.admin_panel_settings_outlined),
                label: const Text('Open with sudo'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Asks for the sudo password.
///
/// Owns its field's controller for the same reason the file browser's name
/// prompt does: the dialog's future completes as the route starts leaving,
/// while the field is still being built for the dismiss animation.
class _PasswordPrompt extends StatefulWidget {
  const _PasswordPrompt();

  @override
  State<_PasswordPrompt> createState() => _PasswordPromptState();
}

class _PasswordPromptState extends State<_PasswordPrompt> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('sudo password'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          labelText: 'Password',
          helperText: 'Kept only while this file is open.',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }
}
