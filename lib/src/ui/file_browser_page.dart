import 'package:flutter/material.dart';

import '../files/file_browser.dart';
import 'file_editor_page.dart';
import 'file_search_page.dart';
import 'terminal_link.dart';

/// One visible line of the tree: an entry, and how many open folders deep it
/// sits below the root.
typedef _Row = ({RemoteEntry entry, int depth});

/// The remote filesystem as a tree, drawn natively.
///
/// Folders open in place rather than replacing the listing, so a file three
/// levels down is reached without losing sight of where it lives. The tree
/// hangs from one root — the host's saved file tree root, or home — and any
/// folder can be made the root instead, with the breadcrumbs climbing back out.
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
    this.terminal,
    this.onFileSelected,
    this.onRootChanged,
    this.onExpandedChanged,
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
  /// terminal — so this page hands the path over instead of navigating.
  final void Function(String path)? onFileSelected;

  /// Reports the root being shown, and [onExpandedChanged] the folders open
  /// under it, so a host that tears this widget down and rebuilds it later —
  /// a drawer does exactly that — can put the tree back the way it was.
  final void Function(String root)? onRootChanged;
  final void Function(Set<String> expanded)? onExpandedChanged;

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

  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _showHidden = false;

  final _filterController = TextEditingController();
  bool _filtering = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _filterController.dispose();
    if (widget.ownsBrowser) widget.browser.close();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final wanted = (widget.initialRoot ?? '').trim();
      // Home costs a round trip, so it is only asked for when the root is
      // written relative to it.
      final home =
          wanted.startsWith('/') ? '/' : await widget.browser.resolveHome();
      await _setRoot(RemotePath.resolve(wanted, home), push: false);
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

    try {
      final entries = await widget.browser.list(root);
      // A crumb tapped while this was loading has moved the tree elsewhere.
      if (!mounted || _root != root) return;
      setState(() {
        _listings[root] = entries;
        _loading = false;
      });
      widget.onRootChanged?.call(root);

      // Only when asked: this types into a live shell, so it is opt-in rather
      // than a surprise waiting on the first "set as root".
      final link = widget.terminal;
      if (link != null && link.follow) link.changeDirectory(root);

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
    if (error != null && mounted) _say(error);
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
    if (entry.isTraversable) {
      await _toggle(entry);
      return;
    }
    if (entry.kind == RemoteEntryKind.other) {
      _say('${entry.name} is not a regular file.');
      return;
    }
    if (entry.kind == RemoteEntryKind.symlink) {
      // Traversable links were handled above, so what is left is a link whose
      // target could not be followed. Opening the editor on it would show
      // "it is no longer there", which is true but blames the wrong thing.
      _say('${entry.name} is a link that points nowhere.');
      return;
    }
    await _openEditor(entry.path);
  }

  Future<void> _openEditor(String path) async {
    final handOver = widget.onFileSelected;
    if (handOver != null) {
      handOver(path);
      return;
    }

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FileEditorPage(browser: widget.browser, path: path),
      ),
    );
    // A save changes the size and timestamp on the row behind us.
    if (changed == true) await _refresh();
  }

  Future<void> _openSearch() async {
    final root = _root;
    final browser = widget.browser;
    if (root == null || browser is! FileSearchCapable) return;

    final hit = await Navigator.of(context).push<String>(
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
    await _reveal(hit);
    if (!mounted) return;
    await _openEditor(hit);
  }

  /// Opens every folder between the root and [path], so a file found by search
  /// sits in the tree with its surroundings rather than appearing from nowhere.
  Future<void> _reveal(String path) async {
    final root = _root;
    if (root == null) return;
    final folders = [
      for (final crumb in RemotePath.crumbs(RemotePath.parent(path)))
        if (crumb.path != root && RemotePath.isWithin(crumb.path, root))
          crumb.path,
    ];
    setState(() => _expanded.addAll(folders));
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
      _say(success);
      await _refresh();
    } on FileBrowserException catch (error) {
      if (mounted) _say(error.message);
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

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Asks before writing the root into the host's config: unlike everything
  /// else in this drawer it outlives the session, and changes where every
  /// later connection opens.
  Future<void> _confirmSaveRoot() async {
    final root = _root;
    final save = widget.onSaveRoot;
    if (root == null || save == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update SSH config?'),
        content: Text(
          'The file tree for ${widget.title} will open at\n\n$root\n\n'
          'every time you connect. This changes the saved host, not just '
          'this session.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await save(root);
      if (mounted) _say('${widget.title} now opens its files at $root');
    } catch (error) {
      if (mounted) _say('Could not update the host config: $error');
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
      // Creating an empty file and leaving the user staring at it would be a
      // half-finished action; what they wanted was to write something in it.
      await _openEditor(target);
    } on FileBrowserException catch (error) {
      if (mounted) _say(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete(RemoteEntry entry) async {
    final isDirectory = entry.kind == RemoteEntryKind.directory;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${entry.name}?'),
        content: Text(
          isDirectory
              ? 'The folder and everything inside it is removed from the host. '
                  'This cannot be undone.'
              : 'The file is removed from the host. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

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
      builder: (_) => _NamePrompt(
        title: title,
        action: action,
        initial: initial,
      ),
    );
  }

  void _showEntryActions(RemoteEntry entry) {
    final terminal = widget.terminal;
    final details = _subtitleFor(entry);

    // Closes the sheet before [action] runs, so a dialog it opens is not
    // stacked on a sheet that is still on its way out.
    VoidCallback closing(BuildContext sheet, VoidCallback action) => () {
          Navigator.of(sheet).pop();
          action();
        };

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // A folder's list is long enough to pass the default nine-sixteenths cap
      // on a short phone, so the sheet sizes to it and scrolls past the screen.
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(_iconFor(entry)),
                title: Text(entry.name, overflow: TextOverflow.ellipsis),
                // The row itself is one line to keep the tree dense, so the
                // size and date it no longer shows are here instead.
                subtitle: Text(
                  details.isEmpty ? entry.path : '${entry.path}\n$details',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: details.isNotEmpty,
              ),
              const Divider(height: 1),
              if (entry.isTraversable) ...[
                ListTile(
                  leading: const Icon(Icons.account_tree_outlined),
                  title: const Text('Set as root'),
                  onTap: closing(sheet, () => _setRoot(entry.path)),
                ),
                ListTile(
                  leading: const Icon(Icons.note_add_outlined),
                  title: const Text('New file here'),
                  onTap: closing(sheet, () => _promptNewFile(entry.path)),
                ),
                ListTile(
                  leading: const Icon(Icons.create_new_folder_outlined),
                  title: const Text('New folder here'),
                  onTap: closing(sheet, () => _promptNewDirectory(entry.path)),
                ),
              ],
              if (terminal != null) ...[
                ListTile(
                  leading: const Icon(Icons.keyboard_outlined),
                  title: const Text('Type path in terminal'),
                  onTap: closing(sheet, () {
                    terminal.typePath(entry.path);
                    _showTerminal();
                  }),
                ),
                if (entry.isTraversable)
                  ListTile(
                    leading: const Icon(Icons.terminal_outlined),
                    title: const Text('Open in terminal'),
                    onTap: closing(sheet, () {
                      terminal.changeDirectory(entry.path);
                      _showTerminal();
                    }),
                  ),
              ],
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('Rename'),
                onTap: closing(sheet, () => _promptRename(entry)),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete'),
                onTap: closing(sheet, () => _confirmDelete(entry)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _history.isEmpty && !_filtering,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        body: Column(
          children: [
            if (_root != null)
              Row(
                children: [
                  Expanded(
                    // Keyed on the root so each move rebuilds it, which is
                    // what re-pins the trail to its deepest crumb. A crumb
                    // hangs the tree from that folder — the way back out of a
                    // "set as root".
                    child: _Breadcrumbs(
                      key: ValueKey(_root),
                      path: _root!,
                      onTap: _setRoot,
                    ),
                  ),
                  // Out of the menu and beside the path it acts on: taking the
                  // shell to where you are looking is what the drawer is most
                  // often opened for.
                  if (widget.terminal case final link?)
                    IconButton(
                      tooltip: 'Open in terminal',
                      icon: const Icon(Icons.terminal_outlined),
                      onPressed: () {
                        link.changeDirectory(_root!);
                        _showTerminal();
                      },
                    ),
                ],
              ),
            const Divider(height: 1),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final canSearch = widget.browser is FileSearchCapable;

    final onClose = widget.onClose;

    return AppBar(
      // Inside a drawer there is no route of our own to pop, and the implied
      // button would pop the page behind it instead.
      automaticallyImplyLeading: onClose == null,
      leading: onClose == null
          ? null
          : IconButton(
              tooltip: 'Close files',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
      title: _filtering
          ? TextField(
              controller: _filterController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Filter the tree',
                border: InputBorder.none,
              ),
              onChanged: (_) => setState(() {}),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _root == null ? 'Files' : RemotePath.basename(_root!),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  widget.title,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
      bottom: (_loading || _busy)
          ? const PreferredSize(
              preferredSize: Size.fromHeight(3),
              child: LinearProgressIndicator(),
            )
          : null,
      actions: [
        if (_filtering && canSearch)
          IconButton(
            tooltip: 'Search file contents',
            onPressed: _openSearch,
            icon: const Icon(Icons.travel_explore_outlined),
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
          icon: Icon(_filtering ? Icons.close : Icons.search),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (choice) {
            final root = _root;
            switch (choice) {
              case 'folder' when root != null:
                _promptNewDirectory(root);
              case 'file' when root != null:
                _promptNewFile(root);
              case 'hidden':
                setState(() => _showHidden = !_showHidden);
              case 'refresh':
                _refresh();
              case 'collapse':
                setState(_expanded.clear);
                _reportExpanded();
              case 'saveRoot':
                _confirmSaveRoot();
              case 'follow':
                final link = widget.terminal;
                if (link != null) setState(() => link.follow = !link.follow);
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'folder', child: Text('New folder')),
            const PopupMenuItem(value: 'file', child: Text('New file')),
            PopupMenuItem(
              value: 'hidden',
              child: Text(_showHidden ? 'Hide dotfiles' : 'Show dotfiles'),
            ),
            const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
            const PopupMenuItem(value: 'collapse', child: Text('Collapse all')),
            if (widget.onSaveRoot != null) ...[
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'saveRoot',
                enabled: _root != null,
                child: const Text('Save root to host config'),
              ),
            ],
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
        // Always scrollable so pull-to-refresh works on a short listing too.
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: rows.length,
        itemBuilder: (context, index) => _buildRow(rows[index]),
      ),
    );
  }

  Widget _buildRow(_Row row) {
    final entry = row.entry;
    final isFolder = entry.isTraversable;
    final isOpen = _expanded.contains(entry.path);

    final Widget? disclosure;
    if (!isFolder) {
      disclosure = null;
    } else if (_loadingFolders.contains(entry.path)) {
      disclosure = const Center(
        child: SizedBox.square(
          dimension: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else {
      disclosure = Icon(isOpen ? Icons.expand_more : Icons.chevron_right);
    }

    return ListTile(
      key: ValueKey(entry.path),
      dense: true,
      visualDensity: VisualDensity.compact,
      // The indent is the tree: each open folder pushes its contents one step
      // right, which is all that says what is inside what.
      contentPadding: EdgeInsetsDirectional.only(start: 4.0 + row.depth * 16),
      horizontalTitleGap: 8,
      minLeadingWidth: 0,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 24, child: disclosure),
          Icon(_iconFor(entry, open: isOpen)),
        ],
      ),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: 'Actions',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.more_vert),
        onPressed: _busy ? null : () => _showEntryActions(entry),
      ),
      onTap: _busy ? null : () => _openEntry(entry),
      onLongPress: _busy ? null : () => _showEntryActions(entry),
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
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Name'),
          validator: (value) {
            final name = value?.trim() ?? '';
            if (name.isEmpty) return 'Enter a name';
            // A slash here would silently move the thing somewhere else,
            // which is never what a rename box is understood to mean.
            if (name.contains('/')) return 'A name cannot contain "/"';
            if (name == '.' || name == '..') return 'Pick another name';
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
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

IconData _iconFor(RemoteEntry entry, {bool open = false}) =>
    switch (entry.kind) {
      RemoteEntryKind.directory =>
        open ? Icons.folder_open_outlined : Icons.folder_outlined,
      RemoteEntryKind.symlink => Icons.link,
      RemoteEntryKind.file => Icons.description_outlined,
      RemoteEntryKind.other => Icons.help_outline,
    };

String _subtitleFor(RemoteEntry entry) {
  final parts = <String>[];
  // Nothing for a directory: the icon already says so.
  if (entry.kind == RemoteEntryKind.symlink) {
    parts.add(entry.targetIsDirectory == null
        ? 'Link'
        : entry.targetIsDirectory!
            ? 'Link to folder'
            : 'Link to file');
  } else if (entry.size != null) {
    parts.add(formatBytes(entry.size!));
  }
  final modified = entry.modified;
  if (modified != null) parts.add(formatTimestamp(modified));
  return parts.join('  ·  ');
}

/// Where the tree hangs from, and a way to hang it from any folder above.
///
/// A phone has no room for a full path in the title bar, and truncating one is
/// worse than useless — it hides the end, which is the part that identifies
/// where you are. Scrolling crumbs keep the whole path reachable.
class _Breadcrumbs extends StatefulWidget {
  const _Breadcrumbs({super.key, required this.path, required this.onTap});

  final String path;
  final void Function(String path) onTap;

  @override
  State<_Breadcrumbs> createState() => _BreadcrumbsState();
}

class _BreadcrumbsState extends State<_Breadcrumbs> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    // Reads left to right like a path, but a trail longer than the bar starts
    // scrolled to its end: the deepest crumb is the one that says where you
    // are, and the ancestors are one swipe away.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_controller.hasClients) return;
      _controller.jumpTo(_controller.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crumbs = RemotePath.crumbs(widget.path);

    return SizedBox(
      height: 44,
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: crumbs.length,
        separatorBuilder: (_, _) => const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 2),
            child: Icon(Icons.chevron_right, size: 16),
          ),
        ),
        itemBuilder: (context, index) {
          final crumb = crumbs[index];
          final isCurrent = index == crumbs.length - 1;
          return Center(
            child: InkWell(
              onTap: isCurrent ? null : () => widget.onTap(crumb.path),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Text(
                  crumb.name,
                  style: isCurrent
                      ? theme.textTheme.labelLarge
                      : theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
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

/// Sizes as a person reads them, not as the server counts them.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final rounded = unit == 0 || value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$rounded ${units[unit]}';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Day and time for this year, day and year for anything older — which is the
/// distinction that actually matters when you are looking for what changed.
String formatTimestamp(DateTime time) {
  final local = time.toLocal();
  final month = _months[local.month - 1];
  if (local.year == DateTime.now().year) {
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.day} $month $hour:$minute';
  }
  return '${local.day} $month ${local.year}';
}
