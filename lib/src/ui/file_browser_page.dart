import 'package:flutter/material.dart';

import '../files/file_browser.dart';
import 'file_editor_page.dart';
import 'file_search_page.dart';

/// The remote filesystem, drawn natively.
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
    this.initialPath,
    this.onInsertPath,
    this.onFileSelected,
    this.onPathChanged,
    this.onClose,
    this.ownsBrowser = true,
  });

  final FileBrowser browser;

  /// The host this is a filesystem for, shown so a user with several sessions
  /// open can tell which one they are looking at.
  final String title;

  /// Where to start. Defaults to whatever the transport calls home.
  final String? initialPath;

  /// Hands a path back to whoever opened this page — the terminal, so far.
  /// Absent when there is nowhere to send it.
  final void Function(String path)? onInsertPath;

  /// Where a tapped file should be opened.
  ///
  /// Null on a phone, where this page pushes the editor as its own screen.
  /// Set when something else owns the editor — a tablet showing it beside the
  /// terminal — so this page hands the path over instead of navigating.
  final void Function(String path)? onFileSelected;

  /// Reports the directory being shown, so a host that tears this widget down
  /// and rebuilds it later — a drawer does exactly that — can put the user
  /// back where they were rather than at home.
  final void Function(String path)? onPathChanged;

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
  /// Where the back gesture goes. A stack rather than "up one directory",
  /// because a user who arrived somewhere deep by tapping a search result
  /// expects back to retrace that, not to climb.
  final List<String> _history = [];

  String? _path;
  List<RemoteEntry> _entries = const [];
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
      final start = widget.initialPath ?? await widget.browser.resolveHome();
      await _open(start, push: false);
    } on FileBrowserException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _open(String path, {bool push = true}) async {
    final previous = _path;
    setState(() {
      _loading = true;
      _error = null;
      if (push && previous != null) _history.add(previous);
      // A name filter belongs to the listing it was typed against. Carried
      // into the next directory it makes that one look empty for no reason,
      // and an emptied box left open is just a keyboard in the way.
      if (previous != path) {
        _filtering = false;
        _filterController.clear();
      }
      _path = path;
    });

    try {
      final entries = await widget.browser.list(path);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      widget.onPathChanged?.call(path);
    } on FileBrowserException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _entries = const [];
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    final path = _path;
    if (path != null) await _open(path, push: false);
  }

  /// True when the gesture was handled here and the page should stay.
  bool _handleBack() {
    if (_filtering) {
      _clearFilter();
      return true;
    }
    if (_history.isEmpty) return false;
    _open(_history.removeLast(), push: false);
    return true;
  }

  void _clearFilter() {
    setState(() {
      _filtering = false;
      _filterController.clear();
    });
  }

  List<RemoteEntry> get _visible {
    final needle = _filterController.text.trim().toLowerCase();
    return [
      for (final entry in _entries)
        if ((_showHidden || !entry.isHidden) &&
            (needle.isEmpty || entry.name.toLowerCase().contains(needle)))
          entry,
    ];
  }

  Future<void> _openEntry(RemoteEntry entry) async {
    if (entry.isTraversable) {
      await _open(entry.path);
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
    final path = _path;
    final browser = widget.browser;
    if (path == null || browser is! FileSearchCapable) return;

    final hit = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => FileSearchPage(
          searcher: browser as FileSearchCapable,
          root: path,
          initialQuery: _filterController.text.trim(),
        ),
      ),
    );
    if (hit == null || !mounted) return;

    // Land in the directory that holds the hit, so the file has context around
    // it rather than appearing out of nowhere.
    await _open(RemotePath.parent(hit));
    if (!mounted) return;
    await _openEditor(hit);
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

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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

  Future<void> _promptNewDirectory() async {
    final path = _path;
    if (path == null) return;
    final name = await _promptForName(title: 'New folder', action: 'Create');
    if (name == null) return;
    await _mutate(
      'Created $name',
      () => widget.browser.makeDirectory(RemotePath.join(path, name)),
    );
  }

  Future<void> _promptNewFile() async {
    final path = _path;
    if (path == null) return;
    final name = await _promptForName(title: 'New file', action: 'Create');
    if (name == null) return;

    final target = RemotePath.join(path, name);
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
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(_iconFor(entry)),
              title: Text(entry.name, overflow: TextOverflow.ellipsis),
              subtitle: Text(entry.path, overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            if (widget.onInsertPath != null)
              ListTile(
                leading: const Icon(Icons.keyboard_outlined),
                title: const Text('Type path in terminal'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  widget.onInsertPath!(entry.path);
                  // Get out of the way so the path can be typed at. As a
                  // drawer that means closing; popping instead would take the
                  // terminal underneath with it.
                  final close = widget.onClose;
                  if (close != null) {
                    close();
                  } else {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _promptRename(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _confirmDelete(entry);
              },
            ),
          ],
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
            if (_path != null) _Breadcrumbs(path: _path!, onTap: _open),
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
                hintText: 'Filter this folder',
                border: InputBorder.none,
              ),
              onChanged: (_) => setState(() {}),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _path == null ? 'Files' : RemotePath.basename(_path!),
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
            switch (choice) {
              case 'folder':
                _promptNewDirectory();
              case 'file':
                _promptNewFile();
              case 'hidden':
                setState(() => _showHidden = !_showHidden);
              case 'refresh':
                _refresh();
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

    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final visible = _visible;
    if (visible.isEmpty) {
      final filtered = _filterController.text.trim().isNotEmpty;
      final hiddenOnly = _entries.isNotEmpty && !_showHidden;
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
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final entry = visible[index];
          return ListTile(
            leading: Icon(_iconFor(entry)),
            title: Text(entry.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(_subtitleFor(entry)),
            trailing: IconButton(
              tooltip: 'Actions',
              icon: const Icon(Icons.more_vert),
              onPressed: _busy ? null : () => _showEntryActions(entry),
            ),
            onTap: _busy ? null : () => _openEntry(entry),
            onLongPress: _busy ? null : () => _showEntryActions(entry),
          );
        },
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

IconData _iconFor(RemoteEntry entry) => switch (entry.kind) {
      RemoteEntryKind.directory => Icons.folder_outlined,
      RemoteEntryKind.symlink => Icons.link,
      RemoteEntryKind.file => Icons.description_outlined,
      RemoteEntryKind.other => Icons.help_outline,
    };

String _subtitleFor(RemoteEntry entry) {
  final parts = <String>[];
  if (entry.kind == RemoteEntryKind.directory) {
    parts.add('Folder');
  } else if (entry.kind == RemoteEntryKind.symlink) {
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

/// Where in the tree we are, and a way back to any of it.
///
/// A phone has no room for a full path in the title bar, and truncating one is
/// worse than useless — it hides the end, which is the part that identifies
/// where you are. Scrolling crumbs keep the whole path reachable.
class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.path, required this.onTap});

  final String path;
  final void Function(String path) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crumbs = RemotePath.crumbs(path);

    return SizedBox(
      height: 44,
      child: ListView.separated(
        // Keyed on the path so each navigation starts scrolled to the deepest
        // crumb. Without it the offset carries over, and walking into a deep
        // tree can land you looking at the middle of the trail.
        key: ValueKey(path),
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: crumbs.length,
        separatorBuilder: (_, _) => const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 2),
            child: Icon(Icons.chevron_right, size: 16),
          ),
        ),
        itemBuilder: (context, index) {
          // Reversed, so the deepest crumb is the one pinned in view: that is
          // the one you need to read, and the one you scroll away from.
          final crumb = crumbs[crumbs.length - 1 - index];
          final isCurrent = index == 0;
          return Center(
            child: InkWell(
              onTap: isCurrent ? null : () => onTap(crumb.path),
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
