import 'dart:math' as math;

import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../files/file_browser.dart';
import '../files/transfers.dart';
import 'file_download.dart';
import 'file_editor_page.dart';
import 'file_search_page.dart';
import 'settings_page.dart' show showDotfiles;
import 'terminal_link.dart';
import 'toast.dart';
import 'tui.dart';

/// One visible line of the tree: an entry, and how many open folders deep it
/// sits below the root.
typedef _Row = ({RemoteEntry entry, int depth});

/// What to do with an upload whose name is already taken in its folder.
enum _Clash { replace, keepBoth, skip }

/// [name] as `name (1).ext`, counting up past every name in [taken]: the
/// name "Keep both" gives an upload.
String _keepBothName(String name, Set<String> taken) {
  // A leading dot starts a dotfile's name, not an extension.
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final extension = dot > 0 ? name.substring(dot) : '';
  for (var n = 1; ; n++) {
    final candidate = '$stem ($n)$extension';
    if (!taken.contains(candidate)) return candidate;
  }
}

/// The remote filesystem as a tree, laid out the way VS Code's Explorer is.
///
/// Dense one-line rows, a chevron on each folder, a file-type icon on each
/// file and a guide line down every open folder. Folders open in place, so a
/// file three levels down is reached without losing sight of where it lives,
/// and the actions live where VS Code keeps them: new file, new folder,
/// upload, refresh and collapse on the root's header, everything else in a
/// context menu — a long press here, the right button with a mouse.
///
/// The tree hangs from one root — the host's saved file tree root, or home.
/// Any folder can be made the root instead, and the root's name opens a menu
/// of the folders above it to climb back out.
///
/// It talks to [FileBrowser] and to nothing else — no SSH, no SFTP, no HTTP
/// anywhere in this file. That is the whole point of the interface: when a
/// daemon behind a port forward replaces SFTP, this page does not change.
///
/// The page owns the browser it is given and closes it on the way out, so the
/// caller's job is one line: construct one, push this, forget it.
class FileBrowserPage extends StatefulWidget {
  const FileBrowserPage({
    super.key,
    required this.browser,
    required this.title,
    this.initialRoot,
    this.initialExpanded = const {},
    this.initialScrollOffset = 0,
    this.terminal,
    this.onFileSelected,
    this.onRootChanged,
    this.onExpandedChanged,
    this.onScrollChanged,
    this.onSaveRoot,
    this.onClose,
    this.ownsBrowser = true,
  });

  final FileBrowser browser;

  /// The host this is a filesystem for, shown so a user with several sessions
  /// open can tell which one they are looking at.
  final String title;

  /// Where the tree hangs from. Null or blank is whatever the transport calls
  /// home, and a relative path or `~/…` is taken from there.
  final String? initialRoot;

  /// Folders to show open, so a drawer rebuilt on every visit does not fold
  /// the whole tree shut each time it is closed.
  final Set<String> initialExpanded;

  /// How far down the tree was scrolled, put back once the folders open in it
  /// have loaded: it fills in a listing at a time, and jumped to any sooner
  /// the offset would be cut down to fit a list still too short.
  final double initialScrollOffset;

  /// The terminal this listing belongs to, when there is one.
  ///
  /// Null when nothing is listening — the actions that reach into a shell then
  /// simply are not offered, the same way search is not offered by a transport
  /// that cannot do it.
  final TerminalLink? terminal;

  /// Where a tapped file should be opened.
  ///
  /// Null on a phone, where this page pushes the editor as its own screen.
  /// Set when something else owns the editor — a tablet showing it beside the
  /// terminal — so this page hands the path over instead of navigating. A
  /// search result also hands over the line it was found on.
  final void Function(String path, {int? line})? onFileSelected;

  /// Reports the root being shown, [onExpandedChanged] the folders open under
  /// it and [onScrollChanged] how far down it is scrolled, so a host that
  /// tears this widget down and rebuilds it later — a drawer does exactly
  /// that — can put the tree back the way it was.
  final void Function(String root)? onRootChanged;
  final void Function(Set<String> expanded)? onExpandedChanged;
  final void Function(double offset)? onScrollChanged;

  /// Writes the root into the host's saved config, so the next connection
  /// opens the tree there. Null hides the option — a page with no saved host
  /// behind it has nothing to write to.
  final Future<void> Function(String root)? onSaveRoot;

  /// Dismisses this view. Null when it is a route and can simply be popped.
  final VoidCallback? onClose;

  /// Whether closing this page should close the browser it was given.
  ///
  /// False when the browser outlives the page: a drawer is rebuilt every time
  /// it opens, and closing the SFTP channel each time would make reopening it
  /// a reconnect.
  final bool ownsBrowser;

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  /// VS Code's rows are 22px, which a finger cannot hit reliably; this keeps
  /// the density while staying a comfortable tap.
  static const double _rowHeight = 32;

  /// One level of nesting — also the width of the chevron column, so each
  /// guide line lands under the chevron of the folder it belongs to.
  static const double _indent = 16;

  /// Roots the tree hung from before this one, for the back gesture. Setting a
  /// folder as root is the one move here that replaces the view, so it is the
  /// one move back undoes.
  final List<String> _history = [];

  String? _root;

  /// Every listing fetched so far, by folder. A folder closed and opened again
  /// shows this at once while its fresh listing is on its way.
  final Map<String, List<RemoteEntry>> _listings = {};

  late final Set<String> _expanded = {...widget.initialExpanded};

  /// Folders whose listing has been asked for and not yet arrived.
  final Set<String> _loadingFolders = {};

  /// The row last tapped, drawn highlighted the way VS Code marks its
  /// selection.
  String? _selected;

  /// Where the last press on a row went down. A long press reports no
  /// position of its own, and the context menu opens under the finger.
  Offset _pressedAt = Offset.zero;

  String? _error;
  bool _loading = true;
  bool _busy = false;

  /// App-wide and saved, so it outlives this tree: the drawer builds a new one
  /// every time it opens.
  bool get _showHidden => showDotfiles.value;

  /// The upload or download under way, which its bar follows, and what the
  /// bar says where the file's name is not enough.
  Transfer? _transfer;
  String? _transferLabel;

  final _filterController = TextEditingController();
  bool _filtering = false;

  /// Reported on every move rather than read on the way out: by the time this
  /// state is disposed, the list it belonged to has already let go of it.
  late final ScrollController _scroll = ScrollController()
    ..addListener(() => widget.onScrollChanged?.call(_scroll.offset));

  @override
  void initState() {
    super.initState();
    showDotfiles.addListener(_redraw);
    _start();
  }

  void _redraw() => setState(() {});

  @override
  void dispose() {
    showDotfiles.removeListener(_redraw);
    _filterController.dispose();
    _scroll.dispose();
    if (widget.ownsBrowser) widget.browser.close();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final wanted = (widget.initialRoot ?? '').trim();
      // Home costs a round trip, so it is only asked for when the root is
      // written relative to it.
      final home = wanted.startsWith('/')
          ? '/'
          : await widget.browser.resolveHome();
      final root = RemotePath.resolve(wanted, home);
      await _setRoot(root, push: false);

      // Once every open folder is in and the list is laid out at its full
      // height. Not over a root picked in the meantime, nor over a user who
      // has already scrolled it themselves.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _root != root || !_scroll.hasClients) return;
      if (_scroll.offset != 0) return;
      _scroll.jumpTo(
        math.min(widget.initialScrollOffset, _scroll.position.maxScrollExtent),
      );
    } on FileBrowserException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  /// Hangs the tree from [root], and fetches it along with every folder left
  /// open beneath it.
  Future<void> _setRoot(String root, {bool push = true}) async {
    final previous = _root;
    setState(() {
      _loading = true;
      _error = null;
      if (push && previous != null && previous != root) _history.add(previous);
      // A name filter belongs to the tree it was typed against. Carried under
      // a new root it makes that one look empty for no reason, and an emptied
      // box left open is just a keyboard in the way.
      if (previous != root) {
        _filtering = false;
        _filterController.clear();
      }
      _root = root;
    });
    // A new root is a new list, read from its top — and the offset reported
    // for the drawer's next visit goes back to the top with it.
    if (previous != root && _scroll.hasClients) _scroll.jumpTo(0);

    try {
      final entries = await widget.browser.list(root);
      // A root picked while this was loading has moved the tree elsewhere.
      if (!mounted || _root != root) return;
      setState(() {
        _listings[root] = entries;
        _loading = false;
      });
      widget.onRootChanged?.call(root);

      // Only when the root moved. Opening the drawer or refreshing loads the
      // same root again without the user going anywhere, and following that
      // would drag a shell sent to a folder inside it back up to the top.
      if (previous != null && previous != root) widget.terminal?.followTo(root);

      // All at once: over SFTP each is a round trip, and waiting for them one
      // after another is what makes a deep tree slow to come back.
      await Future.wait([
        for (final folder in _expanded.toList())
          if (folder != root && RemotePath.isWithin(folder, root))
            _loadFolder(folder),
      ]);
    } on FileBrowserException catch (error) {
      if (!mounted || _root != root) return;
      setState(() {
        _error = error.message;
        _listings.remove(root);
        _loading = false;
      });
    }
  }

  /// Fetches one open folder. A folder that cannot be listed — renamed,
  /// deleted, or never readable — is closed, and the reason returned.
  Future<String?> _loadFolder(String folder) async {
    setState(() => _loadingFolders.add(folder));
    try {
      final entries = await widget.browser.list(folder);
      if (mounted) setState(() => _listings[folder] = entries);
      return null;
    } on FileBrowserException catch (error) {
      if (mounted) {
        setState(() {
          _expanded.remove(folder);
          _listings.remove(folder);
        });
        _reportExpanded();
      }
      return error.message;
    } finally {
      if (mounted) setState(() => _loadingFolders.remove(folder));
    }
  }

  Future<void> _toggle(RemoteEntry folder) async {
    final path = folder.path;
    if (_expanded.contains(path)) {
      setState(() => _expanded.remove(path));
      _reportExpanded();
      return;
    }
    setState(() => _expanded.add(path));
    _reportExpanded();
    final error = await _loadFolder(path);
    if (error != null && mounted) _say(error, ToastificationType.error);
  }

  void _collapseAll() {
    setState(_expanded.clear);
    _reportExpanded();
  }

  void _reportExpanded() => widget.onExpandedChanged?.call(Set.of(_expanded));

  Future<void> _refresh() async {
    final root = _root;
    if (root != null) await _setRoot(root, push: false);
  }

  /// True when the gesture was handled here and the page should stay.
  bool _handleBack() {
    if (_filtering) {
      _clearFilter();
      return true;
    }
    if (_history.isEmpty) return false;
    _setRoot(_history.removeLast(), push: false);
    return true;
  }

  void _clearFilter() {
    setState(() {
      _filtering = false;
      _filterController.clear();
    });
  }

  List<_Row> _rows() {
    final root = _root;
    if (root == null) return const [];
    return _rowsUnder(root, 0, _filterController.text.trim().toLowerCase());
  }

  /// The tree flattened the way the list shows it: each entry, then — if it
  /// is an open folder — everything inside it, one level deeper.
  List<_Row> _rowsUnder(String folder, int depth, String needle) {
    final rows = <_Row>[];
    for (final entry in _listings[folder] ?? const <RemoteEntry>[]) {
      if (entry.isHidden && !_showHidden) continue;
      final below = _expanded.contains(entry.path)
          ? _rowsUnder(entry.path, depth + 1, needle)
          : const <_Row>[];
      // A folder stays while something inside it matches, so the way down to
      // a match is never filtered out from above it.
      if (needle.isNotEmpty &&
          below.isEmpty &&
          !entry.name.toLowerCase().contains(needle)) {
        continue;
      }
      rows
        ..add((entry: entry, depth: depth))
        ..addAll(below);
    }
    return rows;
  }

  Future<void> _openEntry(RemoteEntry entry) async {
    setState(() => _selected = entry.path);
    if (entry.isTraversable) {
      // Opened or shut, a tapped folder is where the user is looking, so a
      // shell told to follow goes there too. A file is not somewhere a shell
      // can be, and opening one moves nothing.
      widget.terminal?.followTo(entry.path);
      await _toggle(entry);
      return;
    }
    if (entry.kind == RemoteEntryKind.other) {
      _say('${entry.name} is not a regular file.', ToastificationType.error);
      return;
    }
    if (entry.kind == RemoteEntryKind.symlink) {
      // Traversable links were handled above, so what is left is a link whose
      // target could not be followed. Opening the editor on it would show
      // "it is no longer there", which is true but blames the wrong thing.
      _say(
        '${entry.name} is a link that points nowhere.',
        ToastificationType.error,
      );
      return;
    }
    await _openEditor(entry.path);
  }

  Future<void> _openEditor(String path, {int? line}) async {
    final handOver = widget.onFileSelected;
    if (handOver != null) {
      handOver(path, line: line);
      return;
    }

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            FileEditorPage(browser: widget.browser, path: path, line: line),
      ),
    );
    // A save can change what is listed; re-read rather than guess.
    if (changed == true) await _refresh();
  }

  Future<void> _openSearch() async {
    final root = _root;
    final browser = widget.browser;
    if (root == null || browser is! FileSearchCapable) return;

    final hit = await Navigator.of(context).push<SearchHit>(
      MaterialPageRoute(
        builder: (_) => FileSearchPage(
          searcher: browser as FileSearchCapable,
          root: root,
          initialQuery: _filterController.text.trim(),
        ),
      ),
    );
    if (hit == null || !mounted) return;

    _clearFilter();
    await _reveal(hit.path);
    if (!mounted) return;
    await _openEditor(hit.path, line: hit.line);
  }

  /// Opens every folder between the root and [path] and selects it, so a file
  /// found by search sits in the tree with its surroundings rather than
  /// appearing from nowhere.
  Future<void> _reveal(String path) async {
    final root = _root;
    if (root == null) return;
    final folders = [
      for (final crumb in RemotePath.crumbs(RemotePath.parent(path)))
        if (crumb.path != root && RemotePath.isWithin(crumb.path, root))
          crumb.path,
    ];
    setState(() {
      _expanded.addAll(folders);
      _selected = path;
    });
    _reportExpanded();
    await Future.wait(folders.map(_loadFolder));
  }

  /// Runs a mutation, then reloads. Everything that changes the remote side
  /// funnels through here so the busy flag, the error banner and the refresh
  /// are not re-implemented four times over.
  Future<void> _mutate(String success, Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      _say(success, ToastificationType.success);
      await _refresh();
    } on FileBrowserException catch (error) {
      if (mounted) _say(error.message, ToastificationType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Steps out of the way so the terminal can be seen. As a drawer that means
  /// closing; popping instead would take the terminal underneath with it.
  void _showTerminal() {
    final close = widget.onClose;
    if (close != null) {
      close();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _say(String message, ToastificationType type) =>
      showToast(context, message, type: type);

  /// Asks before writing the root into the host's config: unlike everything
  /// else in this drawer it outlives the session, and changes where every
  /// later connection opens.
  Future<void> _confirmSaveRoot() async {
    final root = _root;
    final save = widget.onSaveRoot;
    if (root == null || save == null) return;

    final confirmed = await showTuiConfirmDialog(
      context,
      title: 'file tree root',
      message: 'Update SSH config?',
      detail:
          'The file tree for ${widget.title} will open at\n\n$root\n\n'
          'every time you connect. This changes the saved host, not just '
          'this session.',
      confirmLabel: 'Update',
      cancelLabel: 'Cancel',
      confirmVariant: TuiButtonVariant.primary,
    );
    if (!confirmed || !mounted) return;

    try {
      await save(root);
      if (mounted) {
        _say(
          '${widget.title} now opens its files at $root',
          ToastificationType.success,
        );
      }
    } catch (error) {
      if (mounted) {
        _say(
          'Could not update the host config: $error',
          ToastificationType.error,
        );
      }
    }
  }

  Future<void> _promptRename(RemoteEntry entry) async {
    final name = await _promptForName(
      title: 'Rename',
      initial: entry.name,
      action: 'Rename',
    );
    if (name == null || name == entry.name) return;
    await _mutate(
      'Renamed to $name',
      () => widget.browser.rename(
        entry.path,
        RemotePath.join(RemotePath.parent(entry.path), name),
      ),
    );
  }

  /// Opens [folder] first when it is not the root, so what was just made
  /// inside it is in sight rather than behind a closed folder.
  void _openForNew(String folder) {
    if (folder == _root || _expanded.contains(folder)) return;
    setState(() => _expanded.add(folder));
    _reportExpanded();
  }

  Future<void> _promptNewDirectory(String folder) async {
    final name = await _promptForName(title: 'New folder', action: 'Create');
    if (name == null) return;
    _openForNew(folder);
    await _mutate(
      'Created $name',
      () => widget.browser.makeDirectory(RemotePath.join(folder, name)),
    );
  }

  Future<void> _promptNewFile(String folder) async {
    final name = await _promptForName(title: 'New file', action: 'Create');
    if (name == null) return;
    _openForNew(folder);

    final target = RemotePath.join(folder, name);
    setState(() => _busy = true);
    try {
      await widget.browser.writeText(target, '');
      if (!mounted) return;
      await _refresh();
      if (!mounted) return;
      setState(() => _selected = target);
      // Creating an empty file and leaving the user staring at it would be a
      // half-finished action; what they wanted was to write something in it.
      await _openEditor(target);
    } on FileBrowserException catch (error) {
      if (mounted) _say(error.message, ToastificationType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete(RemoteEntry entry) async {
    final isDirectory = entry.kind == RemoteEntryKind.directory;
    final confirmed = await showTuiConfirmDialog(
      context,
      title: isDirectory ? 'delete folder' : 'delete file',
      message: 'Delete ${entry.name}?',
      detail: isDirectory
          ? 'The folder and everything inside it is removed from the host. '
                'This cannot be undone.'
          : 'The file is removed from the host. This cannot be undone.',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
    );
    if (!confirmed) return;

    await _mutate(
      'Deleted ${entry.name}',
      () => widget.browser.delete(entry.path, recursive: isDirectory),
    );
  }

  Future<String?> _promptForName({
    required String title,
    required String action,
    String initial = '',
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) =>
          _NamePrompt(title: title, action: action, initial: initial),
    );
  }

  /// [_say], for the news at the end of a long transfer. The drawer may have
  /// been shut by then, and the answer should not go with it, so it goes
  /// through the app's navigator rather than this page.
  void Function(String, ToastificationType) _sayAnyway() {
    final app = Navigator.of(context, rootNavigator: true).context;
    return (message, type) {
      if (app.mounted) showToast(app, message, type: type);
    };
  }

  /// Sends files picked on the phone into [folder], several at a time. A
  /// name already there asks first: replace that file, keep both, or skip
  /// this one.
  Future<void> _uploadInto(String folder) async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty || !mounted) return;
    final say = _sayAnyway();

    setState(() => _busy = true);
    final sent = <String>[];
    try {
      // Asked of the host rather than the tree, which may not have this
      // folder open or up to date. Links count, broken ones too: an upload
      // never goes through one.
      final taken = {
        for (final entry in await widget.browser.list(folder)) entry.name,
      };
      for (final (index, file) in picked.indexed) {
        final localPath = file.path;
        if (localPath == null) {
          // Straight from a cloud provider, with no copy on the phone to send.
          say(
            '${file.name} is not on the phone, so it was skipped',
            ToastificationType.warning,
          );
          continue;
        }
        // Only the last part of the picker's name: a slash in it would land
        // the file somewhere other than [folder].
        final base = file.name.split('/').last;
        var name = base.isEmpty || base == '.' || base == '..'
            ? 'upload'
            : base;
        var replace = false;
        if (taken.contains(name)) {
          // Never over a file without asking, and with the page gone there is
          // nobody to ask.
          final clash = mounted
              ? await _askClash(name, _keepBothName(name, taken))
              : _Clash.skip;
          switch (clash) {
            case _Clash.replace:
              replace = true;
            case _Clash.keepBoth:
              name = _keepBothName(name, taken);
            case _Clash.skip || null:
              continue;
          }
        }

        final target = RemotePath.join(folder, name);
        try {
          await transfers.run(
            name: name,
            host: widget.title,
            direction: TransferDirection.upload,
            work: (transfer) {
              if (mounted) {
                setState(() {
                  _transfer = transfer;
                  _transferLabel = picked.length == 1
                      ? null
                      : 'Uploading $name (${index + 1} of ${picked.length})';
                });
              }
              return widget.browser.upload(
                localPath,
                target,
                replace: replace,
                onProgress: transfer.report,
                cancel: transfer.cancelled,
              );
            },
          );
        } on FileBrowserException catch (error) {
          // One file cancelled leaves the rest to go.
          if (error.fault == FileBrowserFault.cancelled) continue;
          rethrow;
        }
        taken.add(name);
        sent.add(name);
      }
      if (sent.isNotEmpty) {
        say(
          sent.length == 1
              ? 'Uploaded ${sent.single} to $folder'
              : 'Uploaded ${sent.length} files to $folder',
          ToastificationType.success,
        );
      }
    } on FileBrowserException catch (error) {
      say(error.message, ToastificationType.error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _transfer = null;
          _transferLabel = null;
        });
      }
    }
    // What arrived, in sight: its folder opened and read again.
    if (sent.isNotEmpty && mounted) {
      _openForNew(folder);
      await _refresh();
    }
  }

  /// Replace, keep both or skip, for an upload whose [name] is taken; null
  /// when the question is dismissed, which skips it too.
  Future<_Clash?> _askClash(String name, String bothName) => showDialog<_Clash>(
    context: context,
    builder: (context) => TuiDialog(
      title: 'upload',
      message: '$name is already there',
      detail:
          'Replace it with the file from the phone, keep both with the '
          'new one as "$bothName", or skip it.',
      actions: [
        TuiButton(
          label: 'Skip',
          variant: TuiButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(_Clash.skip),
        ),
        TuiButton(
          label: 'Keep both',
          variant: TuiButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(_Clash.keepBoth),
        ),
        TuiButton(
          label: 'Replace',
          variant: TuiButtonVariant.danger,
          onPressed: () => Navigator.of(context).pop(_Clash.replace),
        ),
      ],
    ),
  );

  /// Brings [entry] down to the phone through [downloadFile], as a file tab
  /// does.
  Future<void> _download(RemoteEntry entry) async {
    setState(() => _busy = true);
    try {
      await downloadFile(
        context,
        widget.browser,
        entry.path,
        host: widget.title,
        onTransfer: (transfer) {
          if (!mounted) return;
          setState(() {
            _transfer = transfer;
            _transferLabel = null;
          });
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Puts [entry]'s text on the clipboard without opening it in a tab.
  ///
  /// Unlike the file tab's Copy content, the text is not here yet, so this
  /// one has to fetch it: the tree's busy flag goes up, which shows the app
  /// bar's bar and stops every row taking another long press until it lands.
  ///
  /// The size the listing already knows is checked first, so a 90 MB log is
  /// refused where it stands rather than coming down the connection to be
  /// declined at the other end. Whether it is text at all stays the browser's
  /// call — the same [FileBrowser.readText] the editor leans on, binary rule
  /// and all — and every refusal it makes is already a sentence to show.
  Future<void> _copyContent(RemoteEntry entry) async {
    final size = entry.size;
    if (size != null && size > copyLimit) {
      _say(tooLargeToCopy(entry.name), ToastificationType.warning);
      return;
    }
    setState(() => _busy = true);
    try {
      final file = await widget.browser.readText(
        entry.path,
        maxBytes: copyLimit,
      );
      if (!mounted) return;
      await copyAndSay(
        context,
        entry.name,
        () => Clipboard.setData(ClipboardData(text: file.text)),
      );
    } on FileBrowserException catch (error) {
      if (!mounted) return;
      // A file with no size in the listing, or one that grew since it: say
      // the same thing the ceiling above says, not the editor's "too large
      // to open here".
      final tooLarge = error.fault == FileBrowserFault.tooLarge;
      _say(
        tooLarge ? tooLargeToCopy(entry.name) : error.message,
        tooLarge ? ToastificationType.warning : ToastificationType.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// VS Code's right-click menu, opened where the finger or the pointer went
  /// down.
  Future<void> _showContextMenu(RemoteEntry entry, Offset pressedAt) async {
    setState(() => _selected = entry.path);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = overlay.globalToLocal(pressedAt);
    final terminal = widget.terminal;
    final isFolder = entry.isTraversable;
    // A file, or a link to one. A folder is not one thing to save or to copy.
    final isFile =
        entry.kind == RemoteEntryKind.file ||
        (entry.kind == RemoteEntryKind.symlink &&
            entry.targetIsDirectory == false);

    PopupMenuItem<VoidCallback> item(String label, VoidCallback action) =>
        PopupMenuItem(value: action, child: Text(label));

    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        at & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        if (isFolder) ...[
          item('New file…', () => _promptNewFile(entry.path)),
          item('New folder…', () => _promptNewDirectory(entry.path)),
          item('Upload here…', () => _uploadInto(entry.path)),
          item('Set as root', () => _setRoot(entry.path)),
          const PopupMenuDivider(),
        ],
        if (isFile) ...[
          item('Download', () => _download(entry)),
          const PopupMenuDivider(),
        ],
        if (terminal != null) ...[
          if (isFolder)
            item('Open in terminal', () {
              terminal.changeDirectory(entry.path);
              _showTerminal();
            }),
          item('Type path in terminal', () {
            terminal.typePath(entry.path);
            _showTerminal();
          }),
        ],
        // Beside Copy path, the other thing a long press puts on the
        // clipboard. Not on a picture: the same name rule that sends one to
        // the image tab, which offers Copy image instead.
        if (isFile && !isImageFile(entry.path))
          item('Copy content', () => _copyContent(entry)),
        item('Copy path', () {
          Clipboard.setData(ClipboardData(text: entry.path));
          _say('Path copied', ToastificationType.success);
        }),
        const PopupMenuDivider(),
        item('Rename…', () => _promptRename(entry)),
        item('Delete', () => _confirmDelete(entry)),
      ],
    );
    // Run once the menu is gone, so a dialog the action opens is not stacked
    // on a menu that is still on its way out.
    action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final root = _root;
    return PopScope(
      canPop: _history.isEmpty && !_filtering,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        body: Column(
          children: [
            if (root != null) _buildRootHeader(root),
            if (_transfer case final transfer?)
              TransferBar(transfer, label: _transferLabel),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final theme = Theme.of(context);
    final canSearch = widget.browser is FileSearchCapable;
    final onClose = widget.onClose;

    return AppBar(
      toolbarHeight: 44,
      titleSpacing: onClose == null ? null : 0,
      // Inside a drawer there is no route of our own to pop, and the implied
      // button would pop the page behind it instead.
      automaticallyImplyLeading: onClose == null,
      leading: onClose == null
          ? null
          : IconButton(
              tooltip: 'Close files',
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 20),
            ),
      title: _filtering
          ? TextField(
              controller: _filterController,
              autofocus: true,
              style: theme.textTheme.bodyMedium,
              decoration: const InputDecoration(
                hintText: 'Filter the tree',
                border: InputBorder.none,
              ),
              onChanged: (_) => setState(() {}),
            )
          // VS Code's view title, with the host after it: several sessions
          // can each have a tree open, and this says whose this is.
          : Text.rich(
              TextSpan(
                text: 'EXPLORER',
                children: [
                  TextSpan(
                    text: '   ${widget.title}',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(letterSpacing: 1.2),
            ),
      // A transfer has a bar of its own, under the root's header.
      bottom: (_loading || _busy) && _transfer == null
          ? const PreferredSize(
              preferredSize: Size.fromHeight(2),
              child: LinearProgressIndicator(minHeight: 2),
            )
          : null,
      actions: [
        if (_filtering && canSearch)
          IconButton(
            tooltip: 'Search file contents',
            onPressed: _openSearch,
            icon: const Icon(Icons.travel_explore_outlined, size: 20),
          ),
        IconButton(
          tooltip: _filtering ? 'Clear filter' : 'Filter by name',
          onPressed: () {
            if (_filtering) {
              _clearFilter();
            } else {
              setState(() => _filtering = true);
            }
          },
          icon: Icon(_filtering ? Icons.close : Icons.search, size: 20),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_horiz, size: 20),
          onSelected: (choice) {
            switch (choice) {
              case 'hidden':
                showDotfiles.choose(!_showHidden);
              case 'saveRoot':
                _confirmSaveRoot();
              case 'follow':
                final link = widget.terminal;
                if (link != null) setState(() => link.follow = !link.follow);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'hidden',
              child: Text(_showHidden ? 'Hide dotfiles' : 'Show dotfiles'),
            ),
            if (widget.onSaveRoot != null)
              PopupMenuItem(
                value: 'saveRoot',
                enabled: _root != null,
                child: const Text('Save root to host config'),
              ),
            if (widget.terminal case final link?) ...[
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                value: 'follow',
                checked: link.follow,
                child: const Text('Follow in terminal'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// The root as VS Code heads a workspace folder: its name in capitals, and
  /// beside it the actions that act on the whole tree.
  Widget _buildRootHeader(String root) {
    final theme = Theme.of(context);
    final isTop = root == '/';

    Widget action(String tooltip, IconData icon, VoidCallback onPressed) =>
        IconButton(
          tooltip: tooltip,
          onPressed: _busy ? null : onPressed,
          icon: Icon(icon, size: 18),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        );

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Expanded(
              // The name is also the way back up: it lists the folders above
              // the root, any of which the tree can be hung from instead.
              child: PopupMenuButton<String>(
                tooltip: 'Change root',
                enabled: !isTop && !_busy,
                onSelected: _setRoot,
                itemBuilder: (_) => [
                  for (final crumb in RemotePath.crumbs(root).reversed.skip(1))
                    PopupMenuItem(value: crumb.path, child: Text(crumb.path)),
                ],
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 12),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          RemotePath.basename(root).toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                      if (!isTop) const Icon(Icons.arrow_drop_down, size: 18),
                    ],
                  ),
                ),
              ),
            ),
            action('New file', Icons.note_add_outlined, () {
              _promptNewFile(root);
            }),
            action('New folder', Icons.create_new_folder_outlined, () {
              _promptNewDirectory(root);
            }),
            action('Upload here', Icons.upload_file_outlined, () {
              _uploadInto(root);
            }),
            action('Refresh', Icons.refresh, _refresh),
            action('Collapse all', Icons.unfold_less, _collapseAll),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final error = _error;
    if (error != null) {
      return _BrowserMessage(
        icon: Icons.folder_off_outlined,
        message: error,
        onRetry: _refresh,
      );
    }

    final listing = _listings[_root];
    if (_loading && listing == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final rows = _rows();
    if (rows.isEmpty) {
      final filtered = _filterController.text.trim().isNotEmpty;
      final hiddenOnly = (listing?.isNotEmpty ?? false) && !_showHidden;
      return _BrowserMessage(
        icon: filtered ? Icons.search_off : Icons.inbox_outlined,
        message: filtered
            ? 'Nothing here matches that.'
            : hiddenOnly
            ? 'Only dotfiles here. Show them from the menu.'
            : 'This folder is empty.',
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        controller: _scroll,
        // Always scrollable so pull-to-refresh works on a short listing too.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemExtent: _rowHeight,
        itemCount: rows.length,
        itemBuilder: (context, index) => _buildRow(rows[index]),
      ),
    );
  }

  Widget _buildRow(_Row row) {
    final theme = Theme.of(context);
    final entry = row.entry;
    final dim = theme.colorScheme.onSurfaceVariant;

    // One column per level: a folder's chevron, or a file's icon in the same
    // place, so every name at a level starts at the same x.
    final Widget lead;
    if (!entry.isTraversable) {
      final (icon, color) = _fileIcon(entry);
      lead = Icon(icon, size: 16, color: color ?? dim);
    } else if (_loadingFolders.contains(entry.path)) {
      lead = const Center(
        child: SizedBox.square(
          dimension: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      );
    } else {
      final isOpen = _expanded.contains(entry.path);
      lead = Icon(isOpen ? Icons.expand_more : Icons.chevron_right, size: 18);
    }

    return Ink(
      key: ValueKey(entry.path),
      color: entry.path == _selected
          ? theme.colorScheme.primary.withValues(alpha: 0.16)
          : null,
      child: InkWell(
        onTap: _busy ? null : () => _openEntry(entry),
        onTapDown: _busy
            ? null
            : (details) => _pressedAt = details.globalPosition,
        onLongPress: _busy ? null : () => _showContextMenu(entry, _pressedAt),
        onSecondaryTapDown: _busy
            ? null
            : (details) => _showContextMenu(entry, details.globalPosition),
        child: Row(
          children: [
            const SizedBox(width: 8),
            // Indent guides: a line down each open folder above this row,
            // under that folder's chevron.
            for (var level = 0; level < row.depth; level++)
              VerticalDivider(
                width: _indent,
                thickness: 1,
                color: theme.colorScheme.outlineVariant,
              ),
            SizedBox(
              width: _indent,
              child: Center(child: lead),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (entry.kind == RemoteEntryKind.symlink)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.link, size: 14, color: dim),
              ),
          ],
        ),
      ),
    );
  }
}

/// Asks for one name, and refuses the ones that would mean something else.
///
/// A `StatefulWidget` rather than a controller created beside `showDialog`:
/// that future completes as the route *starts* leaving, while the field is
/// still being rebuilt for the dismiss animation, so disposing on it throws
/// "a TextEditingController was used after being disposed". Owning the
/// controller here ties it to the element that actually uses it.
class _NamePrompt extends StatefulWidget {
  const _NamePrompt({
    required this.title,
    required this.action,
    required this.initial,
  });

  final String title;
  final String action;
  final String initial;

  @override
  State<_NamePrompt> createState() => _NamePromptState();
}

class _NamePromptState extends State<_NamePrompt> {
  late final _controller = TextEditingController(text: widget.initial);
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return TuiDialog(
      title: widget.title,
      actions: [
        TuiButton(
          label: 'Cancel',
          variant: TuiButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
        TuiButton(label: widget.action, onPressed: _submit),
      ],
      child: Form(
        key: _formKey,
        child: TuiField(
          label: 'Name',
          controller: _controller,
          autofocus: true,
          autocorrect: false,
          validator: (value) {
            final name = value?.trim() ?? '';
            if (name.isEmpty) return 'Enter a name';
            // A slash here would silently move the thing somewhere else,
            // which is never what a rename box is understood to mean.
            if (name.contains('/')) return 'A name cannot contain "/"';
            if (name == '.' || name == '..') return 'Pick another name';
            return null;
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
    );
  }
}

/// File-type icons in the colours VS Code's default theme gives them, by
/// extension.
///
/// ponytail: Material glyphs stand in for the real icon theme — a few dozen
/// types, and most languages share the generic code glyph. Bundle an icon
/// font (vscode-icons, Seti) if per-language glyphs are wanted.
final Map<String, (IconData, Color)> _fileIcons = {
  for (final (extensions, icon, color) in const [
    (['dart'], Icons.flutter_dash, Color(0xFF40C4FF)),
    (['js', 'mjs', 'cjs', 'jsx'], Icons.javascript, Color(0xFFCBCB41)),
    (['ts', 'tsx', 'mts'], Icons.javascript, Color(0xFF519ABA)),
    (['html', 'htm'], Icons.html, Color(0xFFE37933)),
    (['css', 'scss', 'sass', 'less'], Icons.css, Color(0xFF519ABA)),
    (['php'], Icons.php, Color(0xFFA074C4)),
    (['json', 'jsonc'], Icons.data_object, Color(0xFFCBCB41)),
    (
      ['yaml', 'yml', 'toml', 'ini', 'conf', 'cfg', 'env', 'properties'],
      Icons.settings_outlined,
      Color(0xFFA074C4),
    ),
    (['md', 'markdown', 'rst'], Icons.article_outlined, Color(0xFF519ABA)),
    (['txt', 'log'], Icons.notes, Color(0xFF9DA5B4)),
    (['sh', 'bash', 'zsh', 'fish'], Icons.terminal, Color(0xFF8DC149)),
    (
      [
        'py', 'go', 'rs', 'rb', 'java', 'kt', 'kts', 'swift', //
        'c', 'h', 'cc', 'cpp', 'hpp', 'cs', 'lua', 'sql', 'gradle',
      ],
      Icons.code,
      Color(0xFF519ABA),
    ),
    (
      ['png', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'ico', 'bmp'],
      Icons.image_outlined,
      Color(0xFFA074C4),
    ),
    (
      ['zip', 'tar', 'gz', 'tgz', 'xz', 'bz2', '7z', 'rar', 'deb', 'apk'],
      Icons.folder_zip_outlined,
      Color(0xFFE37933),
    ),
    (['lock'], Icons.lock_outline, Color(0xFF9DA5B4)),
  ])
    for (final extension in extensions) extension: (icon, color),
};

/// The icon for anything that is not a folder. Null colour means the muted
/// default, for types the table does not know. A link to a file gets its
/// target's icon — the row marks it as a link on its other end.
(IconData, Color?) _fileIcon(RemoteEntry entry) {
  final broken =
      entry.kind == RemoteEntryKind.symlink && entry.targetIsDirectory == null;
  if (broken) return (Icons.link_off, null);
  if (entry.kind == RemoteEntryKind.other) return (Icons.help_outline, null);
  final dot = entry.name.lastIndexOf('.');
  final extension = dot < 0 ? '' : entry.name.substring(dot + 1).toLowerCase();
  return _fileIcons[extension] ?? (Icons.insert_drive_file_outlined, null);
}

class _BrowserMessage extends StatelessWidget {
  const _BrowserMessage({
    required this.icon,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
