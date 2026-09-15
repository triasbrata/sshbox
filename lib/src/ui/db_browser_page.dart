import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/known_host_store.dart' show HostKeyCheck;
import '../db/db_session.dart';
import 'connect_sheet.dart';
import 'terminal_page.dart' show ConnectionError, openUrl;
import 'toast.dart';

/// Opens [db], asking about a host key through [confirmHostKey] and
/// telling of a sign-in to finish through [onSignIn]: [DbSession.open], or
/// a test's.
typedef DbOpener =
    Future<DbSession> Function(
      DbConnection db, {
      required Future<bool> Function(HostKeyCheck check) confirmHostKey,
      required void Function(Uri url) onSignIn,
    });

/// One database, open: its tables, collections or keys at the side (in a
/// drawer on a phone), and a box to type SQL, a database command or a Redis
/// command into, with what it gave back under it: in a grid, or as JSON.
/// Rows the database lets be changed — a PostgreSQL table's, a MongoDB
/// find's, the key a Redis view shows — are changed in the grid, and saved
/// together.
class DbBrowserPage extends StatefulWidget {
  const DbBrowserPage({
    super.key,
    required this.db,
    required this.title,
    required this.open,
  });

  final DbConnection db;
  final String title;
  final DbOpener open;

  @override
  State<DbBrowserPage> createState() => _DbBrowserPageState();
}

class _DbBrowserPageState extends State<DbBrowserPage> {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _filter = TextEditingController();
  final _query = TextEditingController();
  Timer? _filtering;

  DbSession? _session;
  Object? _error;
  Uri? _signIn;

  /// Bumped by each connect, so one that finishes after another has begun
  /// lets its session go.
  var _attempt = 0;

  Map<String, List<String>>? _objects;
  String? _objectsError;

  DbResult? _result;
  String? _runError;

  /// The query [_result] came from, which a save runs again.
  var _shownQuery = '';

  /// What has been changed in [_result] and not saved, or null when it
  /// cannot be edited.
  DbChanges? _changes;

  /// Whether a result shows as JSON, a card a row, rather than a grid.
  var _asJson = false;
  var _running = false;

  bool get _redis => widget.db.kind == DbKind.redis;

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  @override
  void dispose() {
    _attempt++;
    _filtering?.cancel();
    unawaited(_session?.close());
    _filter.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final attempt = ++_attempt;
    final old = _session;
    setState(() {
      _session = null;
      _error = null;
      _signIn = null;
      // Its rows would be saved through the connection let go of.
      _result = null;
      _changes = null;
    });
    unawaited(old?.close());
    try {
      final session = await widget.open(
        widget.db,
        confirmHostKey: (check) async {
          if (!mounted) return false;
          return confirmHostKey(context, check);
        },
        onSignIn: (url) {
          if (mounted && attempt == _attempt) setState(() => _signIn = url);
        },
      );
      if (!mounted || attempt != _attempt) {
        await session.close();
        return;
      }
      setState(() => _session = session);
      await _loadObjects();
    } catch (error) {
      if (mounted && attempt == _attempt) setState(() => _error = error);
    }
  }

  Future<void> _loadObjects() async {
    final session = _session;
    if (session == null) return;
    setState(() {
      _objects = null;
      _objectsError = null;
    });
    try {
      final objects = await session.objects(_filter.text);
      if (mounted && identical(session, _session)) {
        setState(() => _objects = objects);
      }
    } catch (error) {
      if (mounted && identical(session, _session)) {
        setState(() => _objectsError = '$error');
      }
    }
  }

  /// What [name] under [group] shows, run.
  Future<void> _open(String group, String name) async {
    final session = _session;
    if (session == null) return;
    _scaffold.currentState?.closeEndDrawer();
    try {
      _query.text = await session.queryFor(group, name);
    } catch (error) {
      if (mounted) setState(() => _runError = '$error');
      return;
    }
    await _run();
  }

  /// Runs [query], or what the box holds. Its result drops whatever was
  /// changed in the one before and not saved.
  Future<void> _run([String? query]) async {
    final session = _session;
    final text = query ?? _query.text;
    if (session == null || _running || text.trim().isEmpty) return;
    setState(() {
      _running = true;
      _runError = null;
    });
    try {
      final result = await session.run(text);
      if (mounted) {
        setState(() {
          _result = result;
          _shownQuery = text;
          _changes = result.edit == null ? null : DbChanges();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _result = null;
          _changes = null;
          _runError = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// Makes every change, then reads the rows back. When the database
  /// refuses the first it makes none, and they all stay, to fix or discard;
  /// one refused after others were made is said.
  Future<void> _save() async {
    final edit = _result?.edit;
    final changes = _changes;
    if (edit == null || changes == null || changes.isEmpty || _running) {
      return;
    }
    setState(() => _running = true);
    final String? missed;
    try {
      missed = await edit.save(changes);
    } catch (error) {
      if (mounted) {
        setState(() => _running = false);
        showToast(context, 'Not saved\n$error', type: ToastificationType.error);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _running = false);
    showToast(
      context,
      missed == null ? 'Saved ${_count(changes.count)}' : 'Not all saved\n$missed',
      type: missed == null
          ? ToastificationType.success
          : ToastificationType.warning,
    );
    await _run(_shownQuery);
  }

  static String _count(int changes) =>
      '$changes change${changes == 1 ? '' : 's'}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = _session;
    final objectsLabel = switch (widget.db.kind) {
      DbKind.postgres => 'Tables',
      DbKind.mongo => 'Collections',
      DbKind.redis => 'Keys',
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        return Scaffold(
          key: _scaffold,
          appBar: AppBar(
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  '${widget.db.kind.label} · ${widget.db.summary}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              if (session != null && !wide)
                IconButton(
                  tooltip: objectsLabel,
                  onPressed: () => _scaffold.currentState?.openEndDrawer(),
                  icon: const Icon(Icons.list),
                ),
              IconButton(
                tooltip: 'Reconnect',
                onPressed: _connect,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          endDrawer: session != null && !wide
              ? Drawer(child: SafeArea(child: _objectsPane(objectsLabel)))
              : null,
          body: session == null
              ? _connecting()
              : wide
              ? Row(
                  children: [
                    SizedBox(width: 300, child: _objectsPane(objectsLabel)),
                    const VerticalDivider(width: 1),
                    Expanded(child: _workspace(session)),
                  ],
                )
              : _workspace(session),
        );
      },
    );
  }

  Widget _connecting() {
    final error = _error;
    final signIn = _signIn;
    if (error != null) {
      return ConnectionError(message: '$error', onRetry: _connect);
    }
    if (signIn != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: AuthCheckPrompt(
            url: signIn,
            onOpen: () => openUrl(context, signIn),
          ),
        ),
      );
    }
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Connecting…'),
        ],
      ),
    );
  }

  Widget _objectsPane(String label) {
    final theme = Theme.of(context);
    final objects = _objects;
    final error = _objectsError;
    // A header row per group that has a name, then its names.
    final entries = <(String, String?)>[
      for (final MapEntry(key: group, value: names) in (objects ?? {}).entries) ...[
        if (group.isNotEmpty) (group, null),
        for (final name in names) (group, name),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _filter,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Filter ${label.toLowerCase()}',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                tooltip: 'Refresh',
                onPressed: _loadObjects,
                icon: const Icon(Icons.refresh),
              ),
            ),
            autocorrect: false,
            onChanged: (_) {
              _filtering?.cancel();
              _filtering = Timer(
                const Duration(milliseconds: 400),
                _loadObjects,
              );
            },
          ),
        ),
        Expanded(
          child: error != null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    error,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                )
              : objects == null
              ? const Center(child: CircularProgressIndicator())
              : entries.isEmpty
              ? Center(child: Text('No ${label.toLowerCase()}'))
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, i) => switch (entries[i]) {
                    (final group, null) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(
                        group,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    (final group, final String name) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsetsDirectional.only(
                        start: group.isEmpty ? 16 : 40,
                        end: 16,
                      ),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _open(group, name),
                    ),
                  },
                ),
        ),
      ],
    );
  }

  Widget _workspace(DbSession session) {
    final theme = Theme.of(context);
    final result = _result;
    final error = _runError;
    // What is changed is edited in the grid, and saved from over it.
    final edit = _asJson ? null : result?.edit;
    final changes = edit == null ? null : _changes;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13);
    final note = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // From a hardware keyboard, Ctrl+Enter runs the query and Ctrl+S saves
    // the changes; Redis's one line runs on Enter.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _run,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _run,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              controller: _query,
              style: mono,
              minLines: _redis ? 1 : 3,
              maxLines: _redis ? 1 : 8,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: _redis ? TextInputType.text : TextInputType.multiline,
              textInputAction: _redis ? TextInputAction.go : null,
              onSubmitted: _redis ? (_) => _run() : null,
              decoration: InputDecoration(
                hintText: session.hint,
                hintMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    result?.note ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: note,
                  ),
                ),
                if (result != null && result.rows.isNotEmpty) ...[
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.table_rows_outlined),
                        tooltip: 'Table',
                      ),
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.data_object),
                        tooltip: 'JSON',
                      ),
                    ],
                    selected: {_asJson},
                    onSelectionChanged: (picked) =>
                        setState(() => _asJson = picked.single),
                  ),
                  const SizedBox(width: 8),
                ],
                FilledButton.icon(
                  onPressed: _running ? null : _run,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run'),
                ),
              ],
            ),
          ),
          if (edit != null && changes != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      changes.isEmpty
                          ? 'Tap a cell to edit it, hold a row to delete it'
                          : '${_count(changes.count)} not saved',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: note,
                    ),
                  ),
                  if (edit.adds)
                    IconButton(
                      tooltip: 'Add row',
                      onPressed: _running
                          ? null
                          : () => setState(() => changes.added.add({})),
                      icon: const Icon(Icons.add),
                    ),
                  if (!changes.isEmpty)
                    TextButton(
                      onPressed: _running
                          ? null
                          : () => setState(() => _changes = DbChanges()),
                      child: const Text('Discard'),
                    ),
                  const SizedBox(width: 4),
                  FilledButton.icon(
                    onPressed: _running || changes.isEmpty ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          _running
              ? const LinearProgressIndicator()
              : const Divider(height: 4, thickness: 1),
          Expanded(
            child: error != null
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      error,
                      style: mono.copyWith(color: theme.colorScheme.error),
                    ),
                  )
                : result == null
                ? const SizedBox()
                : _asJson
                ? _ResultJson(result)
                : _ResultGrid(
                    result,
                    changes: _changes,
                    update: _running ? null : setState,
                  ),
          ),
        ],
      ),
    );
  }
}

/// A result's rows as JSON, a card each, laid out as a tree: an object or
/// array with something in it is one line that opens to what is in it. A
/// document shows as it is, a row as its columns and values, and Copy JSON
/// takes the whole of either.
class _ResultJson extends StatelessWidget {
  const _ResultJson(this.result);

  final DbResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Room for a branch's arrow and no more, so the tree stays tight.
    return ListTileTheme.merge(
      minLeadingWidth: 20,
      horizontalTitleGap: 4,
      minVerticalPadding: 0,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: result.rows.length,
        itemBuilder: (context, i) {
          final json = result.json(i);
          final row = jsonDecode(json) as Map<String, dynamic>;
          return Card.outlined(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 12),
                        child: Text(
                          '${i + 1}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Copy JSON',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () {
                          unawaited(
                            Clipboard.setData(ClipboardData(text: json)),
                          );
                          showToast(context, 'Copied');
                        },
                      ),
                    ],
                  ),
                  for (final MapEntry(:key, :value) in row.entries)
                    _JsonNode(name: key, value: value),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One field of a JSON value, [depth] levels in: a line with its value, or,
/// for an object or array with something in it, a line that opens to what
/// is in it, built only while open.
class _JsonNode extends StatelessWidget {
  const _JsonNode({required this.name, required this.value, this.depth = 0});

  final String name;
  final Object? value;
  final int depth;

  /// How many fields or items a line opens to. The rest are counted, and
  /// Copy JSON has them: a long array would otherwise build every line.
  static const _shown = 100;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = this.value;
    // MongoDB's $oid, $date and the like are one value, not a branch.
    final wrapped =
        value is Map &&
        value.length == 1 &&
        '${value.keys.first}'.startsWith(r'$');
    final children = switch (value) {
      Map map when map.isNotEmpty && !wrapped => [
        for (final entry in map.entries) ('${entry.key}', entry.value),
      ],
      List list when list.isNotEmpty => [
        for (final (index, item) in list.indexed) ('$index', item),
      ],
      _ => null,
    };
    final indent = 12.0 + depth * 16;
    final nameSpan = TextSpan(
      text: name,
      style: TextStyle(color: scheme.primary),
    );

    if (children == null) {
      return Padding(
        // Past a branch's arrow, so every name at one depth lines up.
        padding: EdgeInsetsDirectional.fromSTEB(indent + 28, 4, 12, 4),
        child: SelectableText.rich(
          TextSpan(
            style: _ResultGrid._mono,
            children: [
              nameSpan,
              const TextSpan(text: ': '),
              TextSpan(
                text: jsonEncode(value),
                style: TextStyle(
                  color: value is String ? scheme.tertiary : scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final count = children.length;
    return ExpansionTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      minTileHeight: 32,
      controlAffinity: ListTileControlAffinity.leading,
      tilePadding: EdgeInsetsDirectional.only(start: indent, end: 12),
      childrenPadding: EdgeInsets.zero,
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text.rich(
        TextSpan(
          style: _ResultGrid._mono,
          children: [
            nameSpan,
            TextSpan(
              text: value is Map
                  ? '  {$count ${count == 1 ? 'key' : 'keys'}}'
                  : '  [$count ${count == 1 ? 'item' : 'items'}]',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      children: [
        for (final (name, child) in children.take(_shown))
          _JsonNode(name: name, value: child, depth: depth + 1),
        if (count > _shown)
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(indent + 44, 4, 12, 8),
            child: Text(
              '… ${count - _shown} more: Copy JSON has them all',
              style: _ResultGrid._mono.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

/// A result's rows under its column names, scrolling both ways. A tap on a
/// row shows it whole; or, when [changes] can be made to it, a tap on a
/// cell edits it and holding a row deletes it, and what is not saved shows
/// in colour, new rows on top.
class _ResultGrid extends StatelessWidget {
  const _ResultGrid(this.result, {this.changes, this.update});

  final DbResult result;

  /// What has been changed in [result] and not saved, when it can be edited.
  final DbChanges? changes;

  /// Makes a change and shows it: the page's setState. Null while a save
  /// runs, so nothing changes under it.
  final void Function(VoidCallback change)? update;

  static const _mono = TextStyle(fontFamily: 'monospace', fontSize: 13);

  void _showRow(BuildContext context, int index) {
    final details = result.details;
    final text = details != null
        ? details[index]
        : [
            for (var c = 0; c < result.columns.length; c++)
              '${result.columns[c]}: ${result.rows[index][c] ?? 'NULL'}',
          ].join('\n');
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Row ${index + 1}'),
          content: SingleChildScrollView(
            child: SelectableText(text, style: _mono),
          ),
          actions: [
            TextButton(
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: text)));
                showToast(context, 'Copied');
              },
              child: const Text('Copy'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  /// Asks for a new value for column [c] of row [d] as shown, new rows
  /// first.
  Future<void> _editCell(BuildContext context, int d, int c) async {
    final edit = result.edit!;
    final changes = this.changes!;
    final isNew = d < changes.added.length;
    final r = d - changes.added.length;
    final unset = isNew && !changes.added[d].containsKey(c);
    final picked = await showDialog<(String?,)>(
      context: context,
      builder: (context) => _CellEditor(
        column: result.columns[c],
        value: isNew ? changes.added[d][c] : changes.value(result.rows, r, c),
        hint: unset ? edit.unset : 'NULL',
        nulls: edit.nulls,
      ),
    );
    if (picked == null || !context.mounted) return;
    update?.call(() {
      if (isNew) {
        changes.added[d][c] = picked.$1;
      } else {
        changes.set(result.rows, r, c, picked.$1);
      }
    });
  }

  /// Row [d]'s menu, where it was held: show it, and delete or restore it,
  /// or take a new one out.
  Future<void> _rowMenu(BuildContext context, int d, Offset at) async {
    final changes = this.changes!;
    final isNew = d < changes.added.length;
    final r = d - changes.added.length;
    final deleted = changes.deleted.contains(r);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        overlay.globalToLocal(at) & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        if (!isNew)
          PopupMenuItem(
            value: () => _showRow(context, r),
            child: const Text('Show row'),
          ),
        PopupMenuItem(
          value: () => update?.call(() {
            if (isNew) {
              changes.added.removeAt(d);
            } else if (deleted) {
              changes.deleted.remove(r);
            } else {
              changes.deleted.add(r);
            }
          }),
          child: Text(
            isNew
                ? 'Remove new row'
                : deleted
                ? 'Restore row'
                : 'Delete row',
          ),
        ),
      ],
    );
    // Once the menu is gone, so the row's dialog is not stacked on it.
    if (context.mounted) action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final columns = result.columns;
    final rows = result.rows;
    if (columns.isEmpty) return const SizedBox();
    final changes = this.changes;
    final locked = result.edit?.locked ?? const <int>{};
    final unset = result.edit?.unset ?? 'NULL';
    final added = changes?.added ?? const <Map<int, String?>>[];
    final muted = scheme.onSurfaceVariant;

    // Room for its name and the longest of its first 100 values' first
    // lines, between 64 and 320 dp.
    final widths = [
      for (var c = 0; c < columns.length; c++)
        (rows
                        .take(100)
                        .map((row) => (row[c] ?? 'NULL').split('\n').first.length)
                        .fold(columns[c].length, math.max) *
                    8.0 +
                24)
            .clamp(64.0, 320.0),
    ];

    // Column [c]'s value, or [empty] for none, on a fill and in its ink
    // when it is changed.
    Widget cell(
      int c,
      String? value, {
      bool header = false,
      String empty = 'NULL',
      (Color, Color)? fill,
      bool struck = false,
    }) {
      final text = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          value ?? empty,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _mono.copyWith(
            fontWeight: header ? FontWeight.bold : null,
            color: value == null ? muted : fill?.$2,
            decoration: struck ? TextDecoration.lineThrough : null,
          ),
        ),
      );
      return SizedBox(
        width: widths[c],
        child: fill == null ? text : ColoredBox(color: fill.$1, child: text),
      );
    }

    Widget line(BuildContext context, int d) {
      final r = d - added.length;
      if (changes == null) {
        return InkWell(
          onTap: () => _showRow(context, r),
          child: Row(
            children: [
              for (var c = 0; c < columns.length; c++) cell(c, rows[r][c]),
            ],
          ),
        );
      }
      final isNew = r < 0;
      final deleted = changes.deleted.contains(r);
      final cells = isNew
          ? added[d]
          : changes.edits[r] ?? const <int, String?>{};
      return GestureDetector(
        onLongPressStart: update == null
            ? null
            : (details) => _rowMenu(context, d, details.globalPosition),
        child: Row(
          children: [
            for (var c = 0; c < columns.length; c++)
              InkWell(
                onTap: update == null || deleted || locked.contains(c)
                    ? null
                    : () => _editCell(context, d, c),
                child: cell(
                  c,
                  isNew ? cells[c] : changes.value(rows, r, c),
                  empty: isNew && !cells.containsKey(c) ? unset : 'NULL',
                  fill: deleted
                      ? (scheme.errorContainer, scheme.onErrorContainer)
                      : isNew
                      ? (scheme.primaryContainer, scheme.onPrimaryContainer)
                      : cells.containsKey(c)
                      ? (scheme.tertiaryContainer, scheme.onTertiaryContainer)
                      : null,
                  struck: deleted,
                ),
              ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => Scrollbar(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(
              widths.fold(0.0, (sum, width) => sum + width),
              constraints.maxWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ColoredBox(
                  color: scheme.surfaceContainerHigh,
                  child: Row(
                    children: [
                      for (var c = 0; c < columns.length; c++)
                        cell(c, columns[c], header: true),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: added.length + rows.length,
                    itemBuilder: line,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A cell's new value: what is typed, or NULL where there is one. It pops a
/// record of one, so a NULL is told apart from Cancel's null.
class _CellEditor extends StatefulWidget {
  const _CellEditor({
    required this.column,
    required this.value,
    required this.hint,
    required this.nulls,
  });

  final String column;
  final String? value;

  /// What an empty box stands for: NULL, or a new row's untouched cell.
  final String hint;

  /// Whether the value can be NULL.
  final bool nulls;

  @override
  State<_CellEditor> createState() => _CellEditorState();
}

class _CellEditorState extends State<_CellEditor> {
  late final _text = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _ok() => Navigator.of(context).pop(
    // An empty box left empty keeps what it stood for.
    widget.value == null && _text.text.isEmpty ? null : (_text.text,),
  );

  @override
  Widget build(BuildContext context) {
    // One line, where Enter is OK, unless the value has more: a one-line
    // box takes line breaks out of what is edited in it.
    final lines = widget.value?.contains('\n') ?? false;
    return AlertDialog(
      title: Text(widget.column),
      content: TextField(
        controller: _text,
        autofocus: true,
        style: _ResultGrid._mono,
        minLines: 1,
        maxLines: lines ? 8 : 1,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: lines ? null : (_) => _ok(),
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        if (widget.nulls)
          TextButton(
            onPressed: () => Navigator.of(context).pop((null,)),
            child: const Text('Set NULL'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _ok, child: const Text('OK')),
      ],
    );
  }
}
