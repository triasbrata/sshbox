import 'dart:async';
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

  Future<void> _run() async {
    final session = _session;
    final query = _query.text;
    if (session == null || _running || query.trim().isEmpty) return;
    setState(() {
      _running = true;
      _runError = null;
    });
    try {
      final result = await session.run(query);
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _result = null;
          _runError = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

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
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          // Ctrl+Enter runs it from a hardware keyboard; Redis's one line
          // runs on Enter.
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _run,
              const SingleActivator(LogicalKeyboardKey.enter, meta: true): _run,
            },
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
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
              : _ResultGrid(result),
        ),
      ],
    );
  }
}

/// A result's rows as JSON, a card each: a document as it is, a row as its
/// columns and values. Selectable, to copy.
class _ResultJson extends StatelessWidget {
  const _ResultJson(this.result);

  final DbResult result;

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: const EdgeInsets.all(12),
    itemCount: result.rows.length,
    itemBuilder: (context, i) => Card.outlined(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SelectableText(result.json(i), style: _ResultGrid._mono),
      ),
    ),
  );
}

/// A result's rows under its column names, scrolling both ways. A tap on a
/// row shows it whole.
class _ResultGrid extends StatelessWidget {
  const _ResultGrid(this.result);

  final DbResult result;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final columns = result.columns;
    final rows = result.rows;
    if (columns.isEmpty) return const SizedBox();
    final muted = theme.colorScheme.onSurfaceVariant;

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

    Widget line(List<String?> values, {bool header = false}) => Row(
      children: [
        for (var c = 0; c < columns.length; c++)
          SizedBox(
            width: widths[c],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                values[c] ?? 'NULL',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _mono.copyWith(
                  fontWeight: header ? FontWeight.bold : null,
                  color: values[c] == null ? muted : null,
                ),
              ),
            ),
          ),
      ],
    );

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
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: line(columns, header: true),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) => InkWell(
                      onTap: () => _showRow(context, i),
                      child: line(rows[i]),
                    ),
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
