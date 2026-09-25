import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/known_host_store.dart' show HostKeyCheck;
import '../db/db_session.dart';
import '../platform.dart';
import 'connect_sheet.dart';
import 'right_click.dart';
import 'terminal_page.dart' show ConnectionError, openUrl;
import 'toast.dart';
import 'tui.dart';

/// Opens [db], asking about a host key through [confirmHostKey] and
/// telling of a sign-in to finish through [onSignIn]: [DbSession.open], or
/// a test's.
typedef DbOpener = Future<DbSession> Function(
  DbConnection db, {
  required Future<bool> Function(HostKeyCheck check) confirmHostKey,
  required void Function(Uri url) onSignIn,
});

/// How each kind of database's side list reads: the SQL view's tables by
/// schema, the NoSQL view's collections by database, and the KV view's keys,
/// and how its filter is typed. [types] names each type of object as the
/// database reports it ([DbObject.type]), in the order its chips go, with
/// its icon; a key's type has none and shows as the word TYPE gives.
typedef _ObjectView = ({
  String label,
  String hint,
  IconData group,
  Map<String, (String, IconData?)> types,
});

const _views = <DbKind, _ObjectView>{
  DbKind.postgres: (
    label: 'Tables',
    hint: 'Filter tables, or schema.table',
    group: Icons.folder_outlined,
    types: {
      'BASE TABLE': ('Tables', Icons.table_chart_outlined),
      'VIEW': ('Views', Icons.visibility_outlined),
      'MATERIALIZED VIEW': ('Materialized views', Icons.layers_outlined),
      'FOREIGN': ('Foreign tables', Icons.link),
      'LOCAL TEMPORARY': ('Temporary tables', Icons.timer_outlined),
    },
  ),
  DbKind.mongo: (
    label: 'Collections',
    hint: 'Filter collections, or database.collection',
    group: Icons.storage_outlined,
    types: {
      'collection': ('Collections', Icons.description_outlined),
      'view': ('Views', Icons.visibility_outlined),
      'timeseries': ('Time series', Icons.timeline),
    },
  ),
  DbKind.redis: (
    label: 'Keys',
    hint: 'Filter keys, or a pattern like user:*',
    group: Icons.key,
    types: {
      'string': ('String', null),
      'hash': ('Hash', null),
      'list': ('List', null),
      'set': ('Set', null),
      'zset': ('Sorted set', null),
      'stream': ('Stream', null),
    },
  ),
};

/// The MongoDB editor's tabs, as Mongo Compass splits them: the fields of
/// a find, a pipeline, and the free-text command box every other kind of
/// database has.
enum _MongoTab { find, aggregate, command }

/// The SQL editor's tabs, as TablePlus splits them: a filter built from the
/// table's own columns, and the free-text box.
enum _PgTab { filters, sql }

/// One row of the Filters tab, and the field it types into.
class _Condition {
  final value = TextEditingController();
  String column = '';
  PgOp op = PgOp.eq;

  /// Its tick: off leaves the row out without deleting it.
  bool on = true;

  PgFilter get filter => (on: on, column: column, op: op, value: value.text);

  void dispose() => value.dispose();
}

/// A stage the Aggregate tab's Add stage offers, as JSON on one line: the
/// common ones, each arriving as a template to edit.
const _stageTemplates = <String>[
  r'{"$match": {}}',
  r'{"$group": {"_id": "$field", "count": {"$sum": 1}}}',
  r'{"$sort": {"field": -1}}',
  r'{"$project": {"field": 1}}',
  r'{"$limit": 20}',
  r'{"$lookup": {"from": "other", "localField": "id", '
      r'"foreignField": "_id", "as": "joined"}}',
  r'{"$unwind": "$field"}',
  r'{"$count": "count"}',
];

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
  State<DbBrowserPage> createState() => DbBrowserPageState();
}

/// Public so the tab strip can ask [DbBrowserPageState.mayDrop] before it
/// closes the tab out from under changes not saved.
class DbBrowserPageState extends State<DbBrowserPage> {
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

  /// The whole side list as last read, or null while it is read. The filter
  /// narrows it here, without asking the database again; only Refresh and
  /// Reconnect read it anew.
  Map<String, List<DbObject>>? _objects;
  String? _objectsError;

  /// Whether [_objects] stopped at the most keys a Redis list reads, so a
  /// filter still asks the server for the keys it would otherwise miss.
  var _capped = false;

  /// The one type of object the side list shows, when one is picked.
  String? _type;

  /// Schemas and databases folded shut, showing their name alone.
  final _collapsed = <String>{};

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

  /// Which of MongoDB's tabs is shown, and what its fields hold. It is kept
  /// in the page's state, so a trip to another tab of the app and back
  /// comes back to it; it is deliberately not saved with the tab, since a
  /// restored tab has no collection picked and would come back to an empty
  /// Find or a pipeline about nothing.
  var _tab = _MongoTab.find;
  final _mFilter = TextEditingController(text: '{}');
  final _mProject = TextEditingController();
  final _mSort = TextEditingController();
  final _mLimit = TextEditingController(text: '50');
  final _mSkip = TextEditingController();

  /// One per pipeline stage, in the order they run.
  final _mStages = <TextEditingController>[];

  /// Whether Find's Options — project, sort, limit, skip — are shown. Held
  /// here rather than by an ExpansionTile's page storage, which stores a
  /// bool under the same identifier a scroll view inside it stores a double
  /// under, and throws.
  var _mOptions = false;

  /// The collection the Find and Aggregate tabs run on, as the side list
  /// last gave it: its database, and its name.
  var _mDb = '';
  var _mCollection = '';

  /// Which of PostgreSQL's tabs is shown, the table the Filters tab asks
  /// about, and its conditions. Kept in the page's state for the same
  /// reasons MongoDB's fields are.
  var _pgTab = _PgTab.filters;
  var _pgSchema = '';
  var _pgTable = '';
  final _pgConditions = <_Condition>[];

  /// Whether the conditions are joined by OR rather than AND.
  var _pgAny = false;

  /// The columns the Filters tab offers: the ones the table's own
  /// `SELECT *` last came back with. They cost no query of their own, and
  /// are exactly what the grid shows, name for name.
  var _pgColumns = <String>[];

  bool get _redis => widget.db.kind == DbKind.redis;

  bool get _mongo => widget.db.kind == DbKind.mongo;

  bool get _pg => widget.db.kind == DbKind.postgres;

  /// Whether the Filters tab is what a run sends.
  bool get _onFilters => _pg && _pgTab == _PgTab.filters;

  @override
  void initState() {
    super.initState();
    if (_pg) _pgConditions.add(_Condition());
    unawaited(_connect());
  }

  @override
  void dispose() {
    _attempt++;
    _filtering?.cancel();
    unawaited(_session?.close());
    _filter.dispose();
    _query.dispose();
    for (final field in [_mFilter, _mProject, _mSort, _mLimit, _mSkip]) {
      field.dispose();
    }
    for (final stage in _mStages) {
      stage.dispose();
    }
    for (final condition in _pgConditions) {
      condition.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    if (!await mayDrop()) return;
    final attempt = ++_attempt;
    final old = _session;
    setState(() {
      _session = null;
      _error = null;
      _signIn = null;
      // Its rows would be saved through the connection let go of.
      _result = null;
      _changes = null;
      _capped = false;
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
    final filter = _capped ? _filter.text : '';
    final type = _capped ? _type : null;
    final whole = filter.isEmpty && type == null;
    setState(() {
      _objects = null;
      _objectsError = null;
    });
    try {
      final objects = await session.objects(filter, type: type);
      if (mounted && identical(session, _session)) {
        setState(() {
          _objects = objects;
          if (whole) _capped = session.capped(objects);
        });
        // Found too long just now, with a filter already typed or picked.
        if (whole && _capped && (_filter.text.isNotEmpty || _type != null)) {
          await _loadObjects();
        }
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
    if (session == null || !await mayDrop()) return;
    _scaffold.currentState?.closeEndDrawer();
    try {
      _query.text = await session.queryFor(group, name);
    } catch (error) {
      if (mounted) setState(() => _runError = '$error');
      return;
    }
    if (_mongo && mounted) {
      // The Find tab starts afresh on the collection tapped; the pipeline
      // is left as it was, its stages being work of the user's own that
      // reads the same on another collection.
      setState(() {
        _mDb = group;
        _mCollection = name;
        _mFilter.text = '{}';
        _mProject.clear();
        _mSort.clear();
        _mLimit.text = '50';
        _mSkip.clear();
        if (_tab != _MongoTab.command) _tab = _MongoTab.find;
      });
    }
    if (_pg && mounted) {
      // Filters start afresh on the table tapped: its own conditions say
      // nothing about another table's columns.
      setState(() {
        _pgSchema = group;
        _pgTable = name;
        _clearConditions();
        if (_pgTab != _PgTab.sql) _pgTab = _PgTab.filters;
      });
    }
    await _read();
    // The table's own SELECT * just came back: its columns are what the
    // Filters tab offers, whichever tab ran it.
    if (_pg && mounted && _result != null) {
      setState(() => _pgColumns = _result!.columns);
    }
  }

  void _clearConditions() {
    for (final condition in _pgConditions) {
      condition.dispose();
    }
    _pgConditions
      ..clear()
      ..add(_Condition());
  }

  /// Shows another tab of the editor, once whatever is not saved may go:
  /// the grid shown belongs to the tab that ran it.
  Future<void> _pickTab(bool changing, void Function() show) async {
    if (!changing || !await mayDrop() || !mounted) return;
    setState(() {
      show();
      if (_changes != null) _changes = DbChanges();
    });
  }

  /// Runs [query], or what the box holds, once whatever is not saved may go.
  Future<void> _run([String? query]) async {
    if (await mayDrop()) await _read(query);
  }

  /// Whether the changes not saved may go: there are none, or the user said
  /// so. Asked before a run, another table, a reconnect and the tab's close,
  /// each of which reads the rows afresh and leaves nothing of them.
  Future<bool> mayDrop() async {
    final changes = _changes;
    if (changes == null || changes.isEmpty || !mounted) return true;
    return showTuiConfirmDialog(
      context,
      title: 'unsaved',
      message: 'Discard ${_count(changes.count)}?',
      detail:
          'They were never saved to the database, and there is no way back '
          'to them.',
      confirmLabel: 'Discard',
      cancelLabel: 'Keep editing',
    );
  }

  /// Runs [query] and shows what it gives back, dropping whatever was
  /// changed in the result before: every caller has asked about that first.
  Future<void> _read([String? query]) async {
    final session = _session;
    if (session == null || _running) return;
    setState(() {
      _running = true;
      _runError = null;
    });
    try {
      // What the tab shown makes of its fields, which says what is wrong
      // with them rather than sending anything.
      final text = query ?? _queryText();
      if (text.trim().isEmpty) return;
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

  /// What a run sends: the Filters, Find and Aggregate tabs build theirs
  /// from their fields, and every other box holds its own.
  String _queryText() => _onFilters
      ? postgresFilterQuery(
          schema: _pgSchema,
          table: _pgTable,
          filters: [for (final c in _pgConditions) c.filter],
          any: _pgAny,
        )
      : _boxQuery();

  String _boxQuery() => switch (_mongo ? _tab : _MongoTab.command) {
    _MongoTab.find => mongoFindCommand(
      db: _mDb,
      collection: _mCollection,
      filter: _mFilter.text,
      project: _mProject.text,
      sort: _mSort.text,
      limit: _mLimit.text,
      skip: _mSkip.text,
    ),
    _MongoTab.aggregate => mongoAggregateCommand(
      db: _mDb,
      collection: _mCollection,
      stages: [for (final stage in _mStages) stage.text],
    ),
    _MongoTab.command => _query.text,
  };

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
        showToast(context, 'Not saved\n$error', type: TuiToastType.error);
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      // Saved, or gone with what was saved: the read-back has none to ask
      // about.
      _changes = DbChanges();
    });
    showToast(
      context,
      missed == null
          ? 'Saved ${_count(changes.count)}'
          : 'Not all saved\n$missed',
      type: missed == null ? TuiToastType.success : TuiToastType.warning,
    );
    await _read(_shownQuery);
  }

  static String _count(int changes) =>
      '$changes change${changes == 1 ? '' : 's'}';

  /// Shows [type] alone, or every type for null. Past the cap the server
  /// picks them out.
  void _pickType(String? type) {
    setState(() => _type = type);
    if (_capped) {
      _filtering?.cancel();
      unawaited(_loadObjects());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = _session;
    final objectsLabel = _views[widget.db.kind]!.label;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        return Scaffold(
          key: _scaffold,
          appBar: TuiAppBar(
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
        children: [TuiSpinner(), SizedBox(height: 16), Text('Connecting…')],
      ),
    );
  }

  /// The side list, as its kind of database reads: the SQL view's tables
  /// by schema, the NoSQL view's collections by database, and the KV view's
  /// keys by pattern, each narrowed by type too.
  Widget _objectsPane(String label) {
    final theme = Theme.of(context);
    final view = _views[widget.db.kind]!;
    final all = _objects;
    final objects = all == null
        ? null
        : filterObjects(widget.db.kind, all, _filter.text, type: _type);
    final error = _objectsError;
    // A filter shows every match, folded or not.
    final filtering = _filter.text.trim().isNotEmpty || _type != null;
    // A header row per group that has a name, then its names, unless it is
    // folded.
    final entries = <(String, DbObject?)>[
      for (final MapEntry(key: group, value: names)
          in (objects ?? {}).entries) ...[
        if (group.isNotEmpty) (group, null),
        if (group.isEmpty || filtering || !_collapsed.contains(group))
          for (final name in names) (group, name),
      ],
    ];
    // How many of each type were read. Past the cap they are only some, so
    // every type is offered, uncounted.
    final counts = <String, int>{};
    for (final names in (all ?? {}).values) {
      for (final object in names) {
        counts.update(object.type, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final types = {
      for (final type in view.types.keys)
        if (_capped || counts.containsKey(type)) type,
      ...counts.keys.where((type) => type.isNotEmpty),
      ?_type,
    };
    final mark = theme.colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _filter,
            decoration: InputDecoration(
              isDense: true,
              hintText: view.hint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                tooltip: 'Refresh',
                onPressed: _loadObjects,
                icon: const Icon(Icons.refresh),
              ),
            ),
            autocorrect: false,
            onChanged: (_) {
              setState(() {});
              if (!_capped) return;
              _filtering?.cancel();
              _filtering = Timer(
                const Duration(milliseconds: 400),
                _loadObjects,
              );
            },
          ),
        ),
        if (types.length > 1 || _type != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final type in types)
                  TuiFilterChip(
                    label: view.types[type]?.$1 ?? type,
                    count: _capped ? null : counts[type] ?? 0,
                    selected: _type == type,
                    onSelected: (on) => _pickType(on ? type : null),
                  ),
              ],
            ),
          ),
        if (_capped)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Too many ${label.toLowerCase()} to list them all: the filter '
              'and type are matched by the server.',
              style: theme.textTheme.bodySmall?.copyWith(color: mark),
            ),
          ),
        const SizedBox(height: 4),
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
              ? const Center(child: TuiSpinner())
              : entries.isEmpty
              ? Center(child: Text('No ${label.toLowerCase()}'))
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final (group, object) = entries[i];
                    if (object == null) {
                      return ListTile(
                        dense: true,
                        leading: Icon(view.group),
                        title: Text(
                          group,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${objects[group]!.length}',
                              style: TextStyle(color: mark),
                            ),
                            if (!filtering)
                              Icon(
                                _collapsed.contains(group)
                                    ? Icons.expand_more
                                    : Icons.expand_less,
                                color: mark,
                              ),
                          ],
                        ),
                        onTap: filtering
                            ? null
                            : () => setState(() {
                                if (!_collapsed.remove(group)) {
                                  _collapsed.add(group);
                                }
                              }),
                      );
                    }
                    // A table's or a collection's type shows as its icon, a
                    // key's as the word TYPE gives.
                    final icon = view.types[object.type]?.$2;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsetsDirectional.only(
                        start: group.isEmpty ? 16 : 32,
                        end: 16,
                      ),
                      leading: icon == null ? null : Icon(icon, size: 18),
                      title: Text(
                        object.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: icon != null || object.type.isEmpty
                          ? null
                          : Text(
                              object.type,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: mark,
                                fontFamily: TermulFonts.mono,
                              ),
                            ),
                      onTap: () => _open(group, object.name),
                    );
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
    final mono = TextStyle(fontFamily: TermulFonts.mono, fontSize: 13);
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
          if (_mongo)
            _mongoEditor(mono, session, note)
          else if (_pg)
            _pgEditor(mono, session, note)
          else
            _commandBox(mono, session),
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
                if (result?.readOnly case final why?) ...[
                  TuiTooltip(
                    message: why,
                    child: Icon(
                      Icons.lock_outline,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (result != null && result.rows.isNotEmpty) ...[
                  // termul's select, each choice with its word on hover.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 8,
                    children: [
                      for (final (json, label) in [
                        (false, 'Table'),
                        (true, 'JSON'),
                      ])
                        TuiTooltip(
                          message: label,
                          child: TuiButton(
                            label: label,
                            variant: _asJson == json
                                ? TuiButtonVariant.primary
                                : TuiButtonVariant.ghost,
                            onPressed: () => setState(() => _asJson = json),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 8),
                ],
                TuiButton(
                  label: _onFilters ? 'Apply' : 'Run',
                  prefix: '▶',
                  onPressed: _running ? null : _run,
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
                          ? isDesktop
                                ? 'Click a cell to edit it, right-click a '
                                      'row to delete it'
                                : 'Tap a cell to edit it, hold a row to '
                                      'delete it'
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
                    TuiButton(
                      label: 'Discard',
                      variant: TuiButtonVariant.ghost,
                      onPressed: _running
                          ? null
                          : () => setState(() => _changes = DbChanges()),
                    ),
                  const SizedBox(width: 4),
                  TuiButton(
                    label: 'Save',
                    prefix: '✓',
                    onPressed: _running || changes.isEmpty ? null : _save,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          _running
              ? const TuiProgressBar()
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

  /// The free-text box every kind of database has: SQL, a database command,
  /// a Redis command — and, for MongoDB, the Command tab.
  Widget _commandBox(TextStyle mono, DbSession session) => Padding(
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
  );

  /// PostgreSQL's editor, split as TablePlus splits it: a filter built from
  /// the table's own columns, and the free-text SQL box for what it does
  /// not cover. The tabs are over the box, and which is shown decides what
  /// a run sends.
  Widget _pgEditor(TextStyle mono, DbSession session, TextStyle? note) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TuiTabs(
                tabs: const ['Filters', 'SQL'],
                index: _PgTab.values.indexOf(_pgTab),
                onChanged: (i) => _pickTab(
                  _PgTab.values[i] != _pgTab,
                  () => _pgTab = _PgTab.values[i],
                ),
              ),
            ),
          ),
          switch (_pgTab) {
            _PgTab.sql => _commandBox(mono, session),
            _PgTab.filters => _pgFilters(mono, note),
          },
        ],
      );

  /// The Filters tab: a condition a row, AND or OR between them once there
  /// is more than one, and Apply — the Run button, named for what it does
  /// here — under them.
  Widget _pgFilters(TextStyle mono, TextStyle? note) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _pgTable.isEmpty
                    ? 'Tap a table in the list to filter it'
                    : '${_pgSchema.isEmpty ? '' : '$_pgSchema.'}$_pgTable',
                style: note,
              ),
            ),
            if (_pgConditions.length > 1)
              TuiSelect<bool>(
                options: const [(false, 'AND'), (true, 'OR')],
                value: _pgAny,
                onChanged: (any) => setState(() => _pgAny = any),
              ),
          ],
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _pgConditions.length,
            separatorBuilder: (context, index) => const SizedBox(height: 6),
            itemBuilder: (context, index) => _pgConditionRow(index, mono),
          ),
        ),
        Row(
          children: [
            TuiButton(
              label: 'Add condition',
              prefix: '+',
              variant: TuiButtonVariant.ghost,
              onPressed: () => setState(() => _pgConditions.add(_Condition())),
            ),
            const Spacer(),
            TermulTextAction(
              label: 'Clear',
              text: 'CLEAR',
              onTap: () => setState(_clearConditions),
            ),
          ],
        ),
      ],
    ),
  );

  /// One condition: its tick, a column of the table, what to ask of it, and
  /// the value — which the operators that need none do not show.
  Widget _pgConditionRow(int index, TextStyle mono) {
    final condition = _pgConditions[index];
    // The column picked stays on offer even where a new result has not got
    // it, so a filter is never silently emptied.
    final columns = {
      ..._pgColumns,
      if (condition.column.isNotEmpty) condition.column,
    }.toList();
    return Row(
      children: [
        TuiCheckbox(
          value: condition.on,
          onChanged: (on) => setState(() => condition.on = on ?? true),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: TuiDropdown<String>(
            label: 'Column',
            value: condition.column.isEmpty ? null : condition.column,
            hint: 'Column',
            options: [
              for (final name in columns)
                TuiDropdownOption(value: name, label: name),
            ],
            onChanged: (name) => setState(() => condition.column = name ?? ''),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: TuiDropdown<PgOp>(
            label: 'Operator',
            value: condition.op,
            options: [
              for (final op in PgOp.values)
                TuiDropdownOption(value: op, label: op.label),
            ],
            onChanged: (op) => setState(() => condition.op = op ?? PgOp.eq),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 4,
          child: condition.op.needsValue
              ? TextField(
                  controller: condition.value,
                  style: mono,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Value ${index + 1}',
                    hintText: condition.op == PgOp.inList ? 'a, b, c' : null,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                )
              : const SizedBox(),
        ),
        IconButton(
          tooltip: 'Remove condition ${index + 1}',
          onPressed: _pgConditions.length == 1
              ? null
              : () => setState(() => _pgConditions.removeAt(index).dispose()),
          icon: const Icon(Icons.remove_circle_outline),
        ),
      ],
    );
  }

  /// MongoDB's editor, split as Mongo Compass splits it: the fields of a
  /// find, a pipeline of stages, and the command box for what neither
  /// covers. The tabs are over the box, and which is shown decides what a
  /// run sends.
  Widget _mongoEditor(TextStyle mono, DbSession session, TextStyle? note) {
    final on = _mCollection.isEmpty
        ? 'Tap a collection in the list to run on'
        : '${_mDb.isEmpty ? '' : '$_mDb.'}$_mCollection';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TuiTabs(
              tabs: const ['Find', 'Aggregate', 'Command'],
              index: _MongoTab.values.indexOf(_tab),
              onChanged: (i) => _pickTab(
                _MongoTab.values[i] != _tab,
                () => _tab = _MongoTab.values[i],
              ),
            ),
          ),
        ),
        switch (_tab) {
          _MongoTab.command => _commandBox(mono, session),
          _MongoTab.find => _mongoFind(mono, on, note),
          _MongoTab.aggregate => _mongoAggregate(mono, on, note),
        },
      ],
    );
  }

  /// The Find tab: the filter, and the rest behind Options, so a phone
  /// shows the one field that is nearly always the whole query.
  Widget _mongoFind(TextStyle mono, String on, TextStyle? note) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(on, style: note),
        const SizedBox(height: 6),
        _mongoField(_mFilter, 'Filter', r'{"city": "Bandung"}', mono, lines: 3),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _mOptions = !_mOptions),
            icon: Icon(_mOptions ? Icons.expand_less : Icons.expand_more),
            label: const Text('Options'),
          ),
        ),
        if (_mOptions) ...[
          _mongoField(_mProject, 'Project', r'{"name": 1}', mono),
          const SizedBox(height: 8),
          _mongoField(_mSort, 'Sort', r'{"name": 1}', mono),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _mongoField(_mLimit, 'Limit', '50', mono, number: true),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _mongoField(_mSkip, 'Skip', '0', mono, number: true),
              ),
            ],
          ),
        ],
      ],
    ),
  );

  /// The Aggregate tab: a stage a field, in the order they run, each one
  /// removable, and Add stage offering the common ones as templates.
  Widget _mongoAggregate(TextStyle mono, String on, TextStyle? note) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(on, style: note),
        const SizedBox(height: 6),
        if (_mStages.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('No stages yet: add one below.', style: note),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _mStages.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _mongoField(
                    _mStages[index],
                    'Stage ${index + 1}',
                    r'{"$match": {}}',
                    mono,
                    lines: 2,
                  ),
                ),
                IconButton(
                  tooltip: 'Remove stage ${index + 1}',
                  onPressed: () =>
                      setState(() => _mStages.removeAt(index).dispose()),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Builder(
            builder: (anchor) => TuiTooltip(
              message: 'Add a stage',
              child: TuiButton(
                label: 'Add stage',
                prefix: '+',
                variant: TuiButtonVariant.ghost,
                onPressed: () async {
                  final template = await showTuiMenu<String>(
                    context,
                    anchor: anchor,
                    entries: [
                      for (final template in _stageTemplates)
                        TuiMenuItem(
                          value: template,
                          // The operator alone: the template is what it
                          // fills in.
                          label: template.substring(
                            2,
                            template.indexOf('"', 2),
                          ),
                        ),
                    ],
                  );
                  if (template != null) {
                    setState(
                      () => _mStages.add(TextEditingController(text: template)),
                    );
                  }
                },
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _mongoField(
    TextEditingController controller,
    String label,
    String hint,
    TextStyle mono, {
    int lines = 1,
    bool number = false,
  }) => TextField(
    controller: controller,
    style: mono,
    minLines: lines,
    maxLines: lines + 3,
    autocorrect: false,
    enableSuggestions: false,
    keyboardType: number ? TextInputType.number : TextInputType.multiline,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      border: const OutlineInputBorder(),
    ),
  );
}

/// A result's rows as JSON, a card each, laid out as a tree: an object or
/// array with something in it is one line that opens to what is in it. A
/// document shows as it is, a row as its columns and values, and Copy JSON
/// takes the whole of either.
class _ResultJson extends StatelessWidget {
  const _ResultJson(this.result);

  final DbResult result;

  /// A row's card as termul draws a document: its number, Copy JSON, and
  /// its fields as termul's tree.
  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: const EdgeInsets.all(12),
    itemCount: result.rows.length,
    itemBuilder: (context, i) {
      final json = result.json(i);
      return TuiJsonCard(
        index: i + 1,
        data: jsonDecode(json) as Map<String, dynamic>,
        onCopy: () {
          unawaited(Clipboard.setData(ClipboardData(text: json)));
          showToast(context, 'Copied');
        },
      );
    },
  );
}

/// A result's rows under its column names, scrolling both ways. A tap on a
/// row shows it whole; or, when [changes] can be made to it, a tap on a
/// cell edits it and holding a row deletes it, and what is not saved shows
/// in colour, new rows on top.
class _ResultGrid extends StatefulWidget {
  const _ResultGrid(this.result, {this.changes, this.update});

  final DbResult result;

  /// What has been changed in [result] and not saved, when it can be edited.
  final DbChanges? changes;

  /// Makes a change and shows it: the page's setState. Null while a save
  /// runs, so nothing changes under it.
  final void Function(VoidCallback change)? update;

  static final _mono = TextStyle(fontFamily: TermulFonts.mono, fontSize: 13);

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
        builder: (context) => TuiDialog(
          title: 'Row ${index + 1}',
          maxWidth: 520,
          actions: [
            TuiButton(
              label: 'Copy',
              variant: TuiButtonVariant.ghost,
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: text)));
                showToast(context, 'Copied');
              },
            ),
            TuiButton(
              label: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
          child: SingleChildScrollView(
            child: SelectableText(text, style: _mono),
          ),
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
    final picked = await showTuiMenu<VoidCallback>(
      context,
      at: at,
      entries: [
        if (!isNew) menuAction('Show row', () => _showRow(context, r)),
        menuAction(
          isNew
              ? 'Remove new row'
              : deleted
              ? 'Restore row'
              : 'Delete row',
          () => update?.call(() {
            if (isNew) {
              changes.added.removeAt(d);
            } else if (deleted) {
              changes.deleted.remove(r);
            } else {
              changes.deleted.add(r);
            }
          }),
          destructive: !isNew && !deleted,
        ),
      ],
    );
    // Once the menu is gone, so the row's dialog is not stacked on it.
    if (context.mounted) picked?.call();
  }

  @override
  @override
  State<_ResultGrid> createState() => _ResultGridState();
}

class _ResultGridState extends State<_ResultGrid> {
  /// termul's grid list, reached as the primary controller: where it has
  /// scrolled to is what finds the row a long press is on.
  final _rows = ScrollController();

  @override
  void dispose() {
    _rows.dispose();
    super.dispose();
  }

  /// The row, as shown, under [at], or null past the last one.
  ///
  /// ponytail: termul's grid gives a row no long-press of its own, so it is
  /// found from where its list has scrolled to and termul's fixed row height
  /// — 8 above and below a 12px line at 1.3, and a hairline. A callback of
  /// its own is asked of termul.
  int? _rowAt(Offset at, int count) {
    if (!_rows.hasClients) return null;
    final list =
        _rows.position.context.storageContext.findRenderObject() as RenderBox?;
    if (list == null) return null;
    final scale = MediaQuery.textScalerOf(context);
    final height = 16 + scale.scale(12) * 1.3 + 1;
    final y = list.globalToLocal(at).dy + _rows.offset;
    if (y < 0) return null;
    final row = y ~/ height;
    return row < count ? row : null;
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final changes = widget.changes;
    final update = widget.update;
    final columns = result.columns;
    final rows = result.rows;
    if (columns.isEmpty) return const SizedBox();
    final locked = result.edit?.locked ?? const <int>{};
    final added = changes?.added ?? const <Map<int, String?>>[];
    final count = added.length + rows.length;

    // Room for its name and the longest of its first 100 values' first
    // lines, between 64 and 320 dp.
    final widths = [
      for (var c = 0; c < columns.length; c++)
        (rows
                        .take(100)
                        .map(
                          (row) => (row[c] ?? 'NULL').split('\n').first.length,
                        )
                        .fold(columns[c].length, math.max) *
                    8.0 +
                24)
            .clamp(64.0, 320.0),
    ];

    TuiDataGridRow row(int d) {
      final r = d - added.length;
      if (changes == null) {
        return TuiDataGridRow(
          id: '$d',
          cells: [for (final value in rows[r]) TuiDataGridCell(value: value)],
        );
      }
      final isNew = r < 0;
      final cells = isNew
          ? added[d]
          : changes.edits[r] ?? const <int, String?>{};
      final unset = result.edit?.unset ?? 'NULL';
      return TuiDataGridRow(
        id: '$d',
        isNew: isNew,
        deleted: !isNew && changes.deleted.contains(r),
        cells: [
          for (var c = 0; c < columns.length; c++)
            TuiDataGridCell(
              // A new row's untouched cell reads as what it will take.
              value: isNew
                  ? (cells.containsKey(c) ? cells[c] : unset)
                  : changes.value(rows, r, c),
              dirty: cells.containsKey(c),
            ),
        ],
      );
    }

    void menuAt(Offset at) {
      final d = _rowAt(at, count);
      if (d != null) widget._rowMenu(context, d, at);
    }

    final grid = PrimaryScrollController(
      controller: _rows,
      automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
      child: TuiDataGrid(
        minColumnWidth: 64,
        readOnly: changes == null,
        columns: [
          for (var c = 0; c < columns.length; c++)
            TuiDataGridColumn(id: '$c', label: columns[c], width: widths[c]),
        ],
        rows: [for (var d = 0; d < count; d++) row(d)],
        // Read-only, a tap shows the row whole; editable, it edits the cell.
        onSelect: changes != null
            ? null
            : ((int, int) at) => widget._showRow(context, at.$1),
        onCellTap: (d, c) {
          final r = d - added.length;
          if (update == null ||
              locked.contains(c) ||
              (r >= 0 && changes!.deleted.contains(r))) {
            return;
          }
          widget._editCell(context, d, c);
        },
      ),
    );
    if (changes == null || update == null) return grid;
    return GestureDetector(
      onLongPressStart: (details) => menuAt(details.globalPosition),
      onSecondaryTapUp: rightClick(menuAt),
      child: grid,
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
    return TuiDialog(
      title: 'edit cell',
      maxWidth: 420,
      actions: [
        TuiButton(
          label: 'Cancel',
          variant: TuiButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
        if (widget.nulls)
          TuiButton(
            label: 'Set NULL',
            variant: TuiButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop((null,)),
          ),
        TuiButton(label: 'OK', onPressed: _ok),
      ],
      child: TuiField(
        label: widget.column,
        controller: _text,
        autofocus: true,
        minLines: 1,
        maxLines: lines ? 8 : 1,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: lines ? null : (_) => _ok(),
        hint: widget.hint,
      ),
    );
  }
}
