import 'package:flutter/material.dart';

import '../session/session_manager.dart';
import '../session/terminal_session.dart';

/// Browses the remote filesystem over the session that is already open.
///
/// A drawer rather than a page: picking a file is a detour from the shell you
/// are working in, and the shell stays behind it the whole time. Tapping a
/// file hands its path back — what to do with it is [onOpenFile]'s business,
/// not the browser's.
class FilesDrawer extends StatefulWidget {
  const FilesDrawer({
    super.key,
    required this.session,
    required this.onOpenFile,
  });

  final LiveSession session;
  final void Function(String path) onOpenFile;

  /// The directory above [path], or null at the root — which is what hides
  /// the up button rather than letting it walk into nothing.
  static String? parentOf(String path) {
    if (path == '/' || path.isEmpty) return null;
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final cut = trimmed.lastIndexOf('/');
    if (cut < 0) return null;
    return cut == 0 ? '/' : trimmed.substring(0, cut);
  }

  /// Sizes as a person reads them, not as the protocol reports them.
  static String readableSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final rounded = unit == 0 || size >= 10
        ? size.round().toString()
        : size.toStringAsFixed(1);
    return '$rounded ${units[unit]}';
  }

  @override
  State<FilesDrawer> createState() => _FilesDrawerState();
}

class _FilesDrawerState extends State<FilesDrawer> {
  String? _path;
  List<RemoteEntry>? _entries;
  String? _error;

  @override
  void initState() {
    super.initState();
    _openHome();
  }

  Future<void> _openHome() async {
    try {
      final home = await widget.session.homeDirectory();
      await _load(home);
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _load(String path) async {
    setState(() {
      _path = path;
      _entries = null;
      _error = null;
    });

    try {
      final entries = await widget.session.listDirectory(path);
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (!mounted) return;
    setState(() {
      _entries = null;
      _error = error is SshSessionException ? error.message : error.toString();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = _path;
    final parent = path == null ? null : FilesDrawer.parentOf(path);

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Up',
                    onPressed:
                        parent == null ? null : () => _load(parent),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  Expanded(
                    child: Text(
                      path ?? 'Files',
                      // The tail is the part you are standing in, so that is
                      // the half worth keeping when a path runs long.
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Reload',
                    onPressed: path == null ? null : () => _load(path),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    final error = _error;

    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_off_outlined,
                  size: 36, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _openHome,
                icon: const Icon(Icons.home_outlined),
                label: const Text('Back to home'),
              ),
            ],
          ),
        ),
      );
    }

    final entries = _entries;
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) {
      return Center(
        child: Text(
          'Empty directory',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final size = entry.size;

        return ListTile(
          dense: true,
          leading: Icon(
            entry.isDirectory
                ? Icons.folder_outlined
                : Icons.description_outlined,
            color: entry.isDirectory ? theme.colorScheme.primary : null,
          ),
          title: Text(entry.name, overflow: TextOverflow.ellipsis),
          subtitle: entry.isDirectory || size == null
              ? null
              : Text(FilesDrawer.readableSize(size)),
          trailing: entry.isDirectory ? const Icon(Icons.chevron_right) : null,
          onTap: entry.isDirectory
              ? () => _load(entry.path)
              : () => widget.onOpenFile(entry.path),
        );
      },
    );
  }
}
