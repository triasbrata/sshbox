import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../files/file_browser.dart';
import '../files/transfers.dart';
import 'code_languages.dart';
import 'file_download.dart';
import 'key_bar.dart';
import 'mermaid_view.dart';
import 'settings_page.dart' show terminalSettings;
import 'terminal_page.dart' show openUrl;
import 'toast.dart';

/// One remote file in a tab: an image in a viewer, anything else in the
/// editor.
///
/// The choice is made by name alone, so it costs no round trip and survives an
/// app restart for free — the open tabs are saved as paths, and a path that
/// named an image still names one when it comes back.
class FileEditorPage extends StatelessWidget {
  const FileEditorPage({
    super.key,
    required this.browser,
    required this.path,
    this.onClose,
    this.draftKey,
    this.line,
    this.onOpenWeb,
    this.host,
  });

  final FileBrowser browser;
  final String path;
  final String? host;
  final void Function(Uri url)? onOpenWeb;
  final VoidCallback? onClose;
  final String? draftKey;
  final int? line;

  @override
  Widget build(BuildContext context) => _isImage(path)
      ? _ImageFileTab(
          browser: browser,
          path: path,
          host: host,
          onClose: onClose,
        )
      : _TextFileTab(
          browser: browser,
          path: path,
          host: host,
          onClose: onClose,
          draftKey: draftKey,
          line: line,
          onOpenWeb: onOpenWeb,
        );
}

/// The images Flutter decodes on its own.
///
/// Deliberately not the files drawer's image icon list, which also marks svg
/// and ico: dart:ui draws neither without a package, and heic and tiff go the
/// same way. Those stay editor files and say "This looks like a binary file",
/// which already offers Download — better than a viewer that can only fail.
final _imageNames = RegExp(
  r'\.(png|jpe?g|gif|webp|bmp|wbmp)$',
  caseSensitive: false,
);

bool _isImage(String path) => _imageNames.hasMatch(path);

/// Opens one remote file for reading and, if you want, changing.
///
/// Pops `true` when something was actually saved, so the listing behind it
/// knows to reload the size and timestamp it is showing.
class _TextFileTab extends StatefulWidget {
  const _TextFileTab({
    required this.browser,
    required this.path,
    this.onClose,
    this.draftKey,
    this.line,
    this.onOpenWeb,
    this.host,
  });

  final FileBrowser browser;
  final String path;

  /// The host the file is on, as its tab names it, for the Transfers tab to
  /// say where a download came from.
  final String? host;

  /// Opens a web link from the Markdown preview in a tab beside the shell,
  /// as a link in the terminal opens. Null sends it to the phone's browser.
  final void Function(Uri url)? onOpenWeb;

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

  /// 1-based line to put the cursor on once the file is in, as a search
  /// result names it. A new value moves it there again.
  final int? line;

  @override
  State<_TextFileTab> createState() => _TextFileTabState();
}

enum _Conflict { overwrite, reload }

/// ponytail: prefs rewrite their whole store on every write, so drafts of big
/// files are skipped. Move drafts to files if losing those starts to matter.
const _draftLimit = 256 * 1024;

String _draftPrefsKey(String key) => 'editor.draft.$key';

const _prefsFontSize = 'editor.fontSize';
const _prefsWordWrap = 'editor.wordWrap';

class _TextFileTabState extends State<_TextFileTab> {
  final _controller = CodeLineEditingController();

  /// One for a dark page and one for a light, each made once: re_editor
  /// colours the whole file again whenever it is handed a different theme.
  late final _codeThemes = {
    for (final brightness in Brightness.values)
      brightness: codeThemeFor(widget.path, brightness),
  };

  late final _toolbar = MobileSelectionToolbarController(
    builder: _selectionMenu,
  );

  late final _find = CodeFindController(_controller);

  /// The text's own focus, so hardware keys are only taken while the text
  /// has it, and never from the find row's fields inside the editor.
  final _editorFocus = FocusNode(debugLabel: 'file editor text');

  /// What a hardware keyboard does in the text.
  ///
  /// re_editor binds all of this itself on a desktop, but on Android and iOS
  /// only Backspace and Enter. Everything else fell through to Flutter's own
  /// shortcuts, where an arrow means "move focus": the caret left the editor
  /// instead of moving.
  late final Map<ShortcutActivator, VoidCallback> _hardwareKeys = {
    for (final (key, direction) in const [
      (LogicalKeyboardKey.arrowLeft, AxisDirection.left),
      (LogicalKeyboardKey.arrowRight, AxisDirection.right),
      (LogicalKeyboardKey.arrowUp, AxisDirection.up),
      (LogicalKeyboardKey.arrowDown, AxisDirection.down),
    ]) ...{
      SingleActivator(key): () => _controller.moveCursor(direction),
      SingleActivator(key, shift: true): () =>
          _controller.extendSelection(direction),
    },
    const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
        _controller.moveCursorToWordBoundaryBackward,
    const SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
        _controller.moveCursorToWordBoundaryForward,
    const SingleActivator(
      LogicalKeyboardKey.arrowLeft,
      control: true,
      shift: true,
    ): _controller.extendSelectionToWordBoundaryBackward,
    const SingleActivator(
      LogicalKeyboardKey.arrowRight,
      control: true,
      shift: true,
    ): _controller.extendSelectionToWordBoundaryForward,
    const SingleActivator(LogicalKeyboardKey.home):
        _controller.moveCursorToLineStart,
    const SingleActivator(LogicalKeyboardKey.end):
        _controller.moveCursorToLineEnd,
    const SingleActivator(LogicalKeyboardKey.home, shift: true):
        _controller.extendSelectionToLineStart,
    const SingleActivator(LogicalKeyboardKey.end, shift: true):
        _controller.extendSelectionToLineEnd,
    // Tab too would otherwise move focus to the next widget.
    const SingleActivator(LogicalKeyboardKey.tab): () => _useTabs
        ? _controller.replaceSelection('\t')
        : _controller.applyIndent(),
    const SingleActivator(LogicalKeyboardKey.tab, shift: true):
        _controller.applyOutdent,
    const SingleActivator(LogicalKeyboardKey.delete): _controller.deleteForward,
    const SingleActivator(LogicalKeyboardKey.keyA, control: true):
        _controller.selectAll,
    const SingleActivator(LogicalKeyboardKey.keyC, control: true):
        _controller.copy,
    const SingleActivator(LogicalKeyboardKey.keyX, control: true):
        _controller.cut,
    const SingleActivator(LogicalKeyboardKey.keyV, control: true):
        _controller.paste,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
        _controller.undo,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
        _controller.redo,
    const SingleActivator(LogicalKeyboardKey.keyY, control: true):
        _controller.redo,
    const SingleActivator(LogicalKeyboardKey.keyF, control: true):
        _find.findMode,
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
      if (_canSave) _save();
    },
  };

  KeyEventResult _onHardwareKey(FocusNode _, KeyEvent event) {
    if (!_editorFocus.hasPrimaryFocus) return KeyEventResult.ignored;
    for (final MapEntry(key: activator, value: action)
        in _hardwareKeys.entries) {
      if (activator.accepts(event, HardwareKeyboard.instance)) {
        action();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

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

  /// Whether this is a Markdown file, which can be read rendered as well.
  late final _markdown = RegExp(
    r'\.(md|markdown)$',
    caseSensitive: false,
  ).hasMatch(widget.path);

  /// Whether the file shows rendered rather than as written. A Markdown file
  /// opens that way, unless it was opened at a line.
  late bool _preview = _markdown && widget.line == null;

  /// Whether the key bar's Tab types a tab rather than spaces.
  bool _useTabs = false;

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

  /// The download under way, which its bar follows.
  Transfer? _transfer;

  bool get _embedded => widget.onClose != null;

  bool get _canSave => !_loading && _error == null && _dirty && !_saving;

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
    _find.dispose();
    _editorFocus.dispose();
    _controller.removeListener(_onEdited);
    _controller.dispose();
    super.dispose();
  }

  /// Whether the tabs were showing this page when it last looked; null until
  /// its first look.
  bool? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Shown again after another tab, the text takes the keys back, as a
    // shell's terminal does, and after the frame for the same reason. A new
    // tab needs none of this: re_editor focuses its text once the file is in.
    //
    // ponytail: without the soft keyboard, which re_editor raises only for a
    // focus still holding its keyboard token, so the token is taken straight
    // back. Arrows and shortcuts work at once, but typed letters wait for a
    // tap into the text: on Android they come through the keyboard's
    // connection, which re_editor opens with that token. Leave the token if a
    // soft keyboard on every switch to a file is the lesser evil.
    final shown = Visibility.of(context);
    if (shown && _shown == false) _focusText();
    _shown = shown;
  }

  /// Hands the text the keys after the frame, without the soft keyboard: see
  /// [didChangeDependencies]. Never while the preview hides the text.
  void _focusText() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || _error != null || _preview) return;
      _editorFocus.requestFocus();
      _editorFocus.consumeKeyboardToken();
    });
  }

  @override
  void didUpdateWidget(_TextFileTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final line = widget.line;
    if (line != null && line != oldWidget.line && !_loading && _error == null) {
      // A line is a place in the text, so a Markdown file shows its source.
      _preview = false;
      _jumpTo(line);
    }
  }

  /// Puts the cursor at the start of 1-based [line] and scrolls it into the
  /// middle of the view.
  void _jumpTo(int line) {
    _controller.selection = CodeLineSelection.collapsed(
      index: (line - 1).clamp(0, _controller.lineCount - 1),
      offset: 0,
    );
    _controller.makeCursorCenterIfInvisible();
  }

  Future<void> _goToLine() async {
    final answer = await showDialog<String>(
      context: context,
      builder: (_) => _TextPrompt(
        title: 'Go to line',
        label: 'Line, 1 to ${_controller.lineCount}',
        action: 'Go',
        number: true,
      ),
    );
    final line = int.tryParse(answer?.trim() ?? '');
    if (line != null && mounted) _jumpTo(line);
  }

  /// Rendered or as written. Source comes back with its cursor and scroll
  /// position as they were: the text stays built behind the preview.
  void _setPreview(bool preview) {
    setState(() => _preview = preview);
    _focusText();
  }

  /// Runs [action], which works on the text, bringing Source back first if
  /// the preview is up: then after the frame, once the text can take focus.
  void _inSource(VoidCallback action) {
    if (!_preview) {
      action();
      return;
    }
    setState(() => _preview = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) action();
    });
  }

  /// A link tapped in the preview. A web address opens the way a link in the
  /// terminal does. Anything relative is a file on the host or a heading in
  /// this one, so it is named rather than fetched.
  void _openPreviewLink(String text, String? href, String title) {
    final url = Uri.tryParse(href ?? '');
    if (url != null && url.hasScheme) {
      unawaited(openUrl(context, url, inTab: widget.onOpenWeb));
      return;
    }
    showToast(context, 'Not opened: ${href ?? text} is relative to this file');
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
        final name = RemotePath.basename(widget.path).toLowerCase();
        _useTabs = RegExp(r'^\t', multiLine: true).hasMatch(text) ||
            name == 'makefile' ||
            name == 'gnumakefile' ||
            name.endsWith('.mk');
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
      final line = widget.line;
      // After the frame: centring the cursor needs the new text laid out.
      if (line != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _jumpTo(line);
        });
      }
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
      builder: (_) => const _TextPrompt(
        title: 'sudo password',
        label: 'Password',
        helper: 'Kept only while this file is open.',
        action: 'Continue',
        obscure: true,
      ),
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
      showToast(
        context,
        'Saved ${RemotePath.basename(widget.path)}',
        type: ToastificationType.success,
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
        showToast(
          context,
          error.message,
          type: ToastificationType.error,
          action: offerSudo
              ? (
                  label: 'Save with sudo',
                  onPressed: () {
                    if (mounted) _save(root: true);
                  },
                )
              : null,
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

  /// Saves the file on the phone as the host has it, the way the files
  /// drawer's Download does. An edit not saved yet is not in that, so it
  /// asks first.
  Future<void> _download() async {
    if (_dirty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: const Text(
            "The download is the version on the server; your unsaved edits "
            "aren't in it.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Download'),
            ),
          ],
        ),
      );
      if (go != true) return;
    }
    if (!mounted) return;
    await downloadFile(
      context,
      widget.browser,
      widget.path,
      host: widget.host ?? '',
      // Opened through sudo, while a download reads as the login.
      denied: _asRoot
          ? 'Could not download ${RemotePath.basename(widget.path)}: your '
              'login may not read it, and a download does not go through sudo.'
          : null,
      onTransfer: (transfer) {
        if (mounted) setState(() => _transfer = transfer);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _canSave;

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
            if (_markdown)
              IconButton(
                tooltip: _preview ? 'Show source' : 'Show preview',
                onPressed: _loading || _error != null
                    ? null
                    : () => _setPreview(!_preview),
                icon: Icon(_preview ? Icons.code : Icons.preview_outlined),
              ),
            IconButton(
              tooltip: 'Find',
              onPressed: _loading || _error != null
                  ? null
                  : () => _inSource(_find.findMode),
              icon: const Icon(Icons.search),
            ),
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
              tooltip: 'More',
              onSelected: (action) => action(),
              itemBuilder: (context) => [
                // Only the path is needed, so a file that would not open as
                // text can still be saved on the phone.
                PopupMenuItem(
                  value: _download,
                  enabled: _transfer == null,
                  child: const Text('Download'),
                ),
                const PopupMenuDivider(),
                if (!_loading && _error == null) ...[
                  PopupMenuItem(
                    value: () => _inSource(_find.replaceMode),
                    child: const Text('Find and replace'),
                  ),
                  PopupMenuItem(
                    value: () => _inSource(_goToLine),
                    child: const Text('Go to line…'),
                  ),
                  const PopupMenuDivider(),
                ],
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
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_transfer case final transfer?) TransferBar(transfer),
            Expanded(child: _buildBody()),
          ],
        ),
        bottomNavigationBar: _loading || _error != null || _preview
            ? null
            : EditorKeyBar(controller: _controller, useTabs: _useTabs),
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
          // The text stays built behind the preview, so Source comes back
          // with its cursor and scroll position; out of focus meanwhile, so
          // no key reaches text nobody can see.
          child: IndexedStack(
            index: _preview ? 1 : 0,
            sizing: StackFit.expand,
            children: [
              ExcludeFocus(
                excluding: _preview,
                // re_editor opens the keyboard with autocorrect, smart
                // punctuation and capitalisation all off, as a plain text
                // file needs.
                child: Focus(
                  // Not a stop of its own: it only hears the keys the text
                  // lets by.
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: _onHardwareKey,
                  child: CodeEditor(
                    controller: _controller,
                    focusNode: _editorFocus,
                    wordWrap: _wordWrap,
                    toolbarController: _toolbar,
                    findController: _find,
                    findBuilder: (context, find, readOnly) => _FindBar(find),
                    style: CodeEditorStyle(
                      fontSize: _fontSize,
                      // Files are code and config far more often than prose,
                      // and both are unreadable in a proportional face once
                      // alignment matters.
                      fontFamily: 'monospace',
                      codeTheme: _codeThemes[Theme.of(context).brightness],
                    ),
                    indicatorBuilder: (context, editing, chunks, notifier) =>
                        DefaultCodeLineNumber(
                      controller: editing,
                      notifier: notifier,
                    ),
                  ),
                ),
              ),
              if (_preview)
                _MarkdownPreview(
                  text: _controller.text,
                  onTapLink: _openPreviewLink,
                )
              else
                const SizedBox.shrink(),
            ],
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

/// One image in a file tab: fitted to the tab, pinch to zoom and pan, and a
/// double-tap between the whole image and every one of its pixels.
///
/// There is nothing here to edit, so the editor's Save, Find, Go to line and
/// Markdown toggle are not offered and there is no key bar. Download is, since
/// that only ever needed the path — an image the app cannot draw can still be
/// saved on the phone and opened by something that can.
class _ImageFileTab extends StatefulWidget {
  const _ImageFileTab({
    required this.browser,
    required this.path,
    this.host,
    this.onClose,
  });

  final FileBrowser browser;
  final String path;

  /// The host the file is on, as its tab names it, for the Transfers tab to
  /// say where a download came from.
  final String? host;

  /// Dismisses the tab when it is a pane rather than a screen: see
  /// [FileEditorPage.onClose].
  final VoidCallback? onClose;

  @override
  State<_ImageFileTab> createState() => _ImageFileTabState();
}

class _ImageFileTabState extends State<_ImageFileTab> {
  /// ponytail: 20 MB. Every screenshot and camera photo is a small fraction of
  /// that, and the file is only half the cost — to draw it, Flutter decodes it
  /// to width × height × 4 bytes of pixels, which no cap on the file can bound
  /// tightly. Raise it when somebody has a real image bigger than this.
  static const _limit = 20 * 1024 * 1024;

  /// The app's own copy and the directory holding it. The file comes down a
  /// chunk at a time, as a download does, so nothing but the decoded image is
  /// ever held in memory, and the copy goes when the tab does.
  Directory? _temp;
  FileImage? _image;

  /// What the host says the file is, and what it turned out to be.
  int _bytes = 0;
  int? _width;
  int? _height;

  String? _error;
  FileBrowserFault? _fault;
  bool _loading = true;

  /// Stops the copy part way: the tab closed, or the file is past [_limit].
  final _stop = Completer<void>();
  bool _tooLarge = false;

  /// The download under way from the ⋮ menu, which its bar follows.
  Transfer? _transfer;

  final _view = TransformationController();

  /// Where the last double-tap landed, which the zoom keeps under the finger.
  Offset _tapped = Offset.zero;

  bool get _embedded => widget.onClose != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (!_stop.isCompleted) _stop.complete();
    _view.dispose();
    // The decoded pixels are cached under the copy's path, and that path goes
    // with the copy.
    final image = _image;
    if (image != null) unawaited(image.evict());
    // Still loading, and the copy is the download's to clear up on its way
    // out: see the end of [_load].
    if (!_loading) _cleanup();
    super.dispose();
  }

  /// Removes the app's copy. Idempotent, so whichever of the tab closing and
  /// the copy finishing comes last does it, and neither has to know.
  void _cleanup() {
    final temp = _temp;
    _temp = null;
    try {
      temp?.deleteSync(recursive: true);
    } on FileSystemException {
      // Already gone, or never made.
    }
  }

  Future<void> _load() async {
    // On Android, Flutter points systemTemp at the app's own code cache.
    final temp = Directory.systemTemp.createTempSync('image');
    _temp = temp;
    final copy = '${temp.path}/file';
    try {
      await widget.browser.download(
        widget.path,
        copy,
        onProgress: (received, total) {
          _bytes = total;
          // The size lands with the first chunk, so a file past the cap is
          // stopped there rather than pulled down in full to be turned away.
          if (total > _limit && !_stop.isCompleted) {
            _tooLarge = true;
            _stop.complete();
          }
        },
        cancel: _stop.future,
      );
      if (!mounted) return;
      // Checked again for a transport that finishes rather than stopping.
      if (_tooLarge || _bytes > _limit) return _refuse();

      final image = FileImage(File(copy));
      final size = await _sizeOf(image);
      if (!mounted) return;
      setState(() {
        _image = image;
        _width = size.width.round();
        _height = size.height.round();
        _loading = false;
      });
    } on FileBrowserException catch (error) {
      if (!mounted) return;
      if (_tooLarge) return _refuse();
      setState(() {
        _error = error.message;
        _fault = error.fault;
        _loading = false;
      });
    } catch (_) {
      // Whatever the decoder made of it, the answer is the same: this is not
      // an image we can draw. Its own words are for a log, not for a page.
      if (!mounted) return;
      setState(() {
        _error =
            'Could not show ${RemotePath.basename(widget.path)}: it is not an '
            'image this app can open. Download it to open it on the phone.';
        _loading = false;
      });
    } finally {
      // The tab went while this was in flight, so dispose left the copy alone.
      if (!mounted) _cleanup();
    }
  }

  void _refuse() {
    setState(() {
      _error =
          '${formatBytes(_bytes)} is too large to show here. Download it to '
          'open it on the phone.';
      _fault = FileBrowserFault.tooLarge;
      _loading = false;
    });
  }

  /// The image's own pixel size, which is also its decode: a failure here is a
  /// file that is not an image, and what is drawn comes back from the same
  /// cached decode rather than a second one.
  Future<Size> _sizeOf(ImageProvider provider) {
    final done = Completer<Size>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        final size = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        info.dispose();
        if (!done.isCompleted) done.complete(size);
      },
      onError: (error, _) {
        stream.removeListener(listener);
        if (!done.isCompleted) done.completeError(error);
      },
    );
    stream.addListener(listener);
    return done.future;
  }

  void _leave() {
    final close = widget.onClose;
    if (close != null) {
      close();
      return;
    }
    Navigator.of(context).pop();
  }

  /// The same save dialog the files drawer and the editor use.
  Future<void> _download() => downloadFile(
    context,
    widget.browser,
    widget.path,
    host: widget.host ?? '',
    onTransfer: (transfer) {
      if (mounted) setState(() => _transfer = transfer);
    },
  );

  /// Double-tap: every pixel, at the point tapped, or back to the whole image.
  void _toggleZoom(Size viewport) {
    if (_view.value.getMaxScaleOnAxis() > 1.01) {
      _view.value = Matrix4.identity();
      return;
    }
    final width = _width;
    if (width == null || _height == null) return;
    // 1 is the image fitted to the tab, so 100% is however much larger than
    // that its own pixels are on this screen's.
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(width.toDouble(), _height!.toDouble()),
      viewport,
    ).destination;
    final full =
        width / (fitted.width * MediaQuery.devicePixelRatioOf(context));
    // Already showing every pixel, or more: there is nothing to zoom to.
    if (full <= 1.01) return;
    final scale = math.min(full, 8.0);
    _view.value = Matrix4.identity()
      ..translateByDouble(
        -_tapped.dx * (scale - 1),
        -_tapped.dy * (scale - 1),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    final size = _width == null
        ? RemotePath.parent(widget.path)
        : '$_width × $_height · ${formatBytes(_bytes)}';

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          tooltip: _embedded ? 'Close file' : 'Back',
          icon: Icon(_embedded ? Icons.close : Icons.arrow_back),
          onPressed: _leave,
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
              size,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          PopupMenuButton<VoidCallback>(
            tooltip: 'More',
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              // Only the path is needed, so an image that would not open here
              // can still be saved on the phone.
              PopupMenuItem(
                value: _download,
                enabled: _transfer == null,
                child: const Text('Download'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_transfer case final transfer?) TransferBar(transfer),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final error = _error;
    if (error != null) return _EditorError(message: error, fault: _fault);

    // A mid grey behind it: what a transparent PNG leaves showing is as often
    // white as black, and this is the one ground neither disappears into,
    // light theme or dark.
    return ColoredBox(
      color: const Color(0xFF6E6E6E),
      child: LayoutBuilder(
        builder: (context, box) => GestureDetector(
          onDoubleTapDown: (details) => _tapped = details.localPosition,
          onDoubleTap: () => _toggleZoom(box.biggest),
          child: InteractiveViewer(
            transformationController: _view,
            maxScale: 8,
            child: Image(
              image: _image!,
              fit: BoxFit.contain,
              // The decode already worked once, so this is a copy that went
              // away under us rather than a file that was never an image.
              errorBuilder: (context, _, _) => const Center(
                child: Icon(Icons.broken_image_outlined, size: 40),
              ),
            ),
          ),
        ),
      ),
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

/// A Markdown file as it reads, from the text in the editor rather than the
/// host, so an edit not yet saved shows too. Read-only, since editing is
/// Source's, and selectable across blocks.
///
/// Images are never fetched: a relative one is a file on the host, and a web
/// one is as often a tracking badge. Each shows as its alt text.
class _MarkdownPreview extends StatelessWidget {
  const _MarkdownPreview({required this.text, required this.onTapLink});

  final String text;
  final MarkdownTapLinkCallback onTapLink;

  /// ponytail: flutter_markdown_plus parses and builds the whole document on
  /// the UI thread, 0.6 s a megabyte on a desktop and slower on the tablet, so
  /// the preview stops here. Parse in an isolate and build the blocks lazily
  /// if longer files must render in full.
  static const _limit = 100 * 1024;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = theme.textTheme.bodyMedium!;
    var shown = text;
    if (text.length > _limit) {
      final end = text.lastIndexOf('\n', _limit);
      shown = text.substring(0, end > 0 ? end : _limit);
    }

    return ValueListenableBuilder(
      // Code in the terminal's font, following Settings as it changes.
      valueListenable: terminalSettings,
      builder: (context, terminal, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (shown.length < text.length)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                'Only the first 100 KB is shown here. Source has the whole '
                'file.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: SelectionArea(
              child: Markdown(
                data: shown,
                onTapLink: onTapLink,
                builders: {'code': MermaidBuilder()},
                imageBuilder: (uri, title, alt) => Text.rich(
                  TextSpan(
                    children: [
                      const WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Icon(Icons.image_outlined, size: 16),
                      ),
                      TextSpan(
                        text: ' ${alt == null || alt.isEmpty ? uri : alt}',
                      ),
                    ],
                  ),
                  style: body.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                // The package's own picks a fixed blue for links and a
                // colour that vanishes on a dark page for checkboxes.
                styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  a: TextStyle(
                    color: scheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: scheme.primary,
                  ),
                  code: body.copyWith(
                    fontFamily: terminal.fontFamily,
                    fontFamilyFallback: terminal.fontFamilyFallback,
                    fontSize: body.fontSize! * 0.9,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  checkbox: body.copyWith(color: scheme.primary),
                  // Sized to what they hold, so a wide one scrolls sideways
                  // the way a code block does, rather than squeezing.
                  tableColumnWidth: const IntrinsicColumnWidth(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Find, and replace once asked for, across the top of the editor.
///
/// re_editor runs the search and keeps the state; this is only the face, sized
/// for a finger rather than a mouse.
class _FindBar extends StatelessWidget implements PreferredSizeWidget {
  const _FindBar(this.controller);

  final CodeFindController controller;

  static const _rowHeight = 48.0;

  @override
  Size get preferredSize {
    final value = controller.value;
    if (value == null) return Size.zero;
    return Size.fromHeight(_rowHeight * (value.replaceMode ? 2 : 1));
  }

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final result = value.result;
    final found = result != null;
    // A search that found nothing also comes back without a result, so the
    // pattern is what tells "nothing yet" from "nothing there".
    final count = value.searching || value.option.pattern.isEmpty
        ? ''
        : found
            ? '${result.index + 1}/${result.matches.length}'
            : 'No results';

    Widget row(Widget field, List<Widget> trailing) => SizedBox(
          height: _rowHeight,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Expanded(child: field),
              ...trailing,
            ],
          ),
        );
    Widget field(TextEditingController text, FocusNode focus, String hint) =>
        TextField(
          controller: text,
          focusNode: focus,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            border: InputBorder.none,
            isDense: true,
          ),
        );

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row(
            field(
              controller.findInputController,
              controller.findInputFocusNode,
              'Find',
            ),
            [
              Text(count, style: Theme.of(context).textTheme.bodySmall),
              IconButton(
                tooltip: 'Previous match',
                onPressed: found ? controller.previousMatch : null,
                icon: const Icon(Icons.keyboard_arrow_up),
              ),
              IconButton(
                tooltip: 'Next match',
                onPressed: found ? controller.nextMatch : null,
                icon: const Icon(Icons.keyboard_arrow_down),
              ),
              IconButton(
                tooltip: 'Replace…',
                isSelected: value.replaceMode,
                onPressed: controller.toggleMode,
                icon: const Icon(Icons.find_replace),
              ),
              IconButton(
                tooltip: 'Close find',
                onPressed: controller.close,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (value.replaceMode)
            row(
              field(
                controller.replaceInputController,
                controller.replaceInputFocusNode,
                'Replace with',
              ),
              [
                TextButton(
                  onPressed: found ? controller.replaceMatch : null,
                  child: const Text('Replace'),
                ),
                TextButton(
                  onPressed: found ? controller.replaceAllMatches : null,
                  child: const Text('Replace all'),
                ),
                const SizedBox(width: 8),
              ],
            ),
        ],
      ),
    );
  }
}

/// Asks for one line of text: the sudo password, a line number.
///
/// Owns its field's controller for the same reason the file browser's name
/// prompt does: the dialog's future completes as the route starts leaving,
/// while the field is still being built for the dismiss animation.
class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.label,
    required this.action,
    this.helper,
    this.obscure = false,
    this.number = false,
  });

  final String title;
  final String label;
  final String action;
  final String? helper;
  final bool obscure;
  final bool number;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
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
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: widget.obscure,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: widget.number ? TextInputType.number : null,
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.helper,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}
