import 'dart:async';

import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../data/secret_store.dart';
import '../db/db_session.dart';
import '../models/host_profile.dart';
import '../session/port_forwards.dart';
import '../session/session_log.dart';
import '../session/session_manager.dart';
import 'db_editor_page.dart';
import 'host_edit_page.dart';
import 'known_hosts_page.dart';
import 'logs_page.dart';
import 'os_icon.dart';
import 'port_forwarding_page.dart';
import 'settings_page.dart';

class HostsPage extends StatefulWidget {
  const HostsPage({
    super.key,
    required this.repository,
    required this.secrets,
    required this.sessions,
    required this.onOpenHost,
  });

  final HostRepository repository;
  final SecretStore secrets;
  final SessionManager sessions;

  /// Opens another session on the host, even one that already has some — the
  /// tab strip is how you get back to those.
  final Future<void> Function(String hostId) onOpenHost;

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  List<HostProfile>? _hosts;
  List<DbConnection>? _databases;

  final _search = TextEditingController();

  /// What the search field holds, trimmed and in lower case: empty shows
  /// every host and database.
  String _query = '';

  /// On a phone the search field takes the name's place while it is open;
  /// a tablet has room for both, and always shows it.
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _reload();
    widget.sessions.addListener(_onSessionsChanged);
  }

  @override
  void dispose() {
    widget.sessions.removeListener(_onSessionsChanged);
    _search.dispose();
    super.dispose();
  }

  /// Re-read rather than just redrawn: a session can write into a saved host
  /// — the file tree saves its root there — and an Edit opened on the copy
  /// held here would then save the old root straight back.
  void _onSessionsChanged() {
    if (mounted) _reload();
  }

  Future<void> _reload() async {
    final hosts = await widget.repository.load();
    final databases = await loadDatabases();
    if (!mounted) return;
    setState(() {
      _hosts = hosts;
      _databases = databases;
    });
  }

  Future<void> _openEditor({HostProfile? existing}) async {
    final saved = await Navigator.of(context).push<HostProfile>(
      MaterialPageRoute(
        builder: (_) => HostEditPage(
          repository: widget.repository,
          secrets: widget.secrets,
          existing: existing,
          notifyKeys: widget.sessions.notifyKeys,
        ),
      ),
    );
    // An open tab keeps the profile it was opened with; without this, a new
    // file tree root would wait for the tab to be closed and opened again.
    if (saved != null) widget.sessions.updateHost(saved);
    await _reload();
  }

  /// Copies [host] into a saved host of its own, so a variant of it needs no
  /// retyping. Every field the editor shows comes along — [HostProfile.copyWith]
  /// carries the whole profile, so one added later is not silently dropped —
  /// and so do the password, private key and passphrase, under the new id, for
  /// a copy that connects without the secret being typed again.
  ///
  /// What belongs to the original alone stays there: the copy is a new host,
  /// with no open session, no history of its own in the logs, and no
  /// notification key until it first connects, when it gets one of its own.
  Future<void> _duplicate(HostProfile host) async {
    final copy = host.copyWith(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      label: _copyName(host.displayName),
    );
    // Both lists in the same order, so a secret added to SecretKeys travels
    // with a duplicate too. Read and written, never logged or shown.
    final from = SecretKeys.allFor(host.id);
    final to = SecretKeys.allFor(copy.id);
    for (var i = 0; i < from.length; i++) {
      await widget.secrets.write(to[i], await widget.secrets.read(from[i]));
    }
    await widget.repository.upsert(copy);
    await _reload();
  }

  /// `<name> (copy)`, or `(copy 2)` and on while that is taken — compared
  /// against what the cards show, so no two hosts on Home read alike.
  String _copyName(String name) {
    final taken = {
      for (final host in _hosts ?? const <HostProfile>[]) host.displayName,
    };
    for (var n = 1; ; n++) {
      final candidate = n == 1 ? '$name (copy)' : '$name (copy $n)';
      if (!taken.contains(candidate)) return candidate;
    }
  }

  Future<void> _confirmDelete(HostProfile host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${host.displayName}?'),
        content: const Text(
          'Every open session for this host is closed, its saved password or '
          'private key is removed from the device keystore, and its '
          'notification key is revoked.',
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
    await widget.sessions.closeHost(host.id);
    // Not waited for: the relay may be slow or out of reach. The key goes to
    // no host from now on either way, and waits to be revoked until the
    // relay confirms.
    unawaited(widget.sessions.notifyKeys?.revoke(host.id));
    await widget.repository.delete(host.id);
    await _reload();
  }

  /// The database editor, for a new one or [existing].
  Future<void> _editDatabase([DbConnection? existing]) async {
    final changed = await editDatabase(
      context,
      hosts: _hosts ?? const [],
      secrets: widget.secrets,
      existing: existing,
    );
    if (changed) await _afterDatabaseChange();
  }

  Future<void> _deleteDatabase(DbConnection db) async {
    if (await deleteDatabase(context, db, widget.secrets)) {
      await _afterDatabaseChange();
    }
  }

  /// Re-reads the list, and closes the tab of a database no longer saved:
  /// it would only keep its connection open.
  Future<void> _afterDatabaseChange() async {
    await _reload();
    final saved = {for (final db in _databases ?? const []) db.id};
    for (final tab in widget.sessions.dbTabs) {
      if (!saved.contains(tab.db.id)) widget.sessions.closeDb(tab);
    }
  }

  /// Whether [text], a card's name and address, is what the search asks for.
  bool _matches(String text) =>
      _query.isEmpty || text.toLowerCase().contains(_query);

  void _toggleSearch() => setState(() {
    _searching = !_searching;
    if (!_searching) {
      _search.clear();
      _query = '';
    }
  });

  Widget _searchField({bool autofocus = false}) {
    final scheme = Theme.of(context).colorScheme;
    final edge = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)),
    );
    return TextField(
      controller: _search,
      autofocus: autofocus,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.search,
      onChanged: (text) => setState(() => _query = text.trim().toLowerCase()),
      decoration: InputDecoration(
        hintText: 'Search',
        prefixIcon: const Icon(Icons.search),
        isDense: true,
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: edge,
        enabledBorder: edge,
      ),
    );
  }

  /// Everywhere else Home goes, by name, behind one button. A row of named
  /// buttons said them all at once, but took a strip of the page and still
  /// scrolled out of sight on a phone; opened, this says the same names.
  Widget _menu() {
    Future<void> push(Widget page) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));

    return PopupMenuButton<String>(
      tooltip: 'More',
      onSelected: (choice) async {
        switch (choice) {
          case 'forwards':
            await push(
              PortForwardingPage(
                forwards: portForwards,
                repository: widget.repository,
                secrets: widget.secrets,
              ),
            );
            // A host made there belongs here too.
            await _reload();
          case 'transfers':
            widget.sessions.showTransfers(select: true);
          case 'logs':
            await push(
              LogsPage(
                repository: widget.repository,
                onOpenHost: widget.onOpenHost,
              ),
            );
          case 'known':
            await push(KnownHostsPage(repository: widget.repository));
          case 'settings':
            await push(SettingsPage(notifyKeys: widget.sessions.notifyKeys));
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'forwards', child: Text('Port forwarding')),
        PopupMenuItem(value: 'transfers', child: Text('Transfers')),
        PopupMenuItem(value: 'logs', child: Text('Logs')),
        PopupMenuItem(value: 'known', child: Text('Known hosts')),
        PopupMenuItem(value: 'settings', child: Text('Settings')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _hosts;
    final databases = _databases;
    // Material's compact breakpoint, as the cards and the tab strip use.
    final wide = MediaQuery.sizeOf(context).width >= 600;

    return Scaffold(
      appBar: AppBar(
        title: !wide && _searching
            ? _searchField(autofocus: true)
            : const _Wordmark(),
        actions: [
          if (wide)
            SizedBox(width: 320, child: _searchField())
          else
            IconButton(
              tooltip: _searching ? 'Close search' : 'Search',
              onPressed: _toggleSearch,
              icon: Icon(_searching ? Icons.close : Icons.search),
            ),
          _menu(),
        ],
      ),
      floatingActionButton: _AddButton(
        onHost: () => _openEditor(),
        onDatabase: () => _editDatabase(),
      ),
      body: hosts == null || databases == null
          ? const Center(child: CircularProgressIndicator())
          : hosts.isEmpty && databases.isEmpty
          ? const _EmptyState()
          : LayoutBuilder(
              builder: (context, constraints) {
                // Material's compact breakpoint, as the tab strip uses: one
                // column on a phone, three once there is a tablet's width.
                final columns = constraints.maxWidth < 600 ? 1 : 3;
                final byId = {for (final host in hosts) host.id: host};

                Widget hostCard(HostProfile host) {
                  final open = widget.sessions.sessionsFor(host.id);
                  return _HostTile(
                    host: host,
                    sessionCount: open.length,
                    activeCount: open.where((s) => s.isConnected).length,
                    onOpen: () => widget.onOpenHost(host.id),
                    onEdit: () => _openEditor(existing: host),
                    onDuplicate: () => _duplicate(host),
                    onDelete: () => _confirmDelete(host),
                    onCloseSessions: () => widget.sessions.closeHost(host.id),
                  );
                }

                Widget databaseCard(DbConnection db) {
                  final host = byId[db.hostId];
                  return _DatabaseTile(
                    db: db,
                    host: host,
                    onOpen: () =>
                        widget.sessions.openDb(db, db.displayName(host)),
                    onEdit: () => _editDatabase(db),
                    onDelete: () => _deleteDatabase(db),
                  );
                }

                // Rows of cards rather than a grid, so a card is as tall as
                // its text at any font size, and every card in a row as tall
                // as the tallest. The cards' 6 dp margins make the rest of
                // the gutters.
                List<Widget> rows(List<Widget> cards) => [
                  for (var start = 0; start < cards.length; start += columns)
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = start; i < start + columns; i++)
                            Expanded(
                              child: i < cards.length
                                  ? cards[i]
                                  : const SizedBox(),
                            ),
                        ],
                      ),
                    ),
                ];

                // The host last used first, by the newest session the log
                // has for each; one never used keeps its place from the
                // saved list, after them.
                final used = <String, int>{};
                for (final (i, entry) in sessionLog.entries.indexed) {
                  used.putIfAbsent(entry.host.id, () => i);
                }
                int rank(int saved) =>
                    used[hosts[saved].id] ?? sessionLog.entries.length;
                final order = [for (var i = 0; i < hosts.length; i++) i]
                  ..sort((a, b) {
                    final byUse = rank(a).compareTo(rank(b));
                    return byUse != 0 ? byUse : a.compareTo(b);
                  });
                final shown = [
                  for (final i in order)
                    if (_matches('${hosts[i].displayName} ${hosts[i].target}'))
                      hosts[i],
                ];
                bool live(HostProfile host) => widget.sessions
                    .sessionsFor(host.id)
                    .any((s) => s.isConnected);

                final sections = [
                  // A shell up on a host brings it to the top, where it is
                  // looked for while it runs.
                  ('Active', [
                    for (final host in shown)
                      if (live(host)) hostCard(host),
                  ]),
                  ('Hosts', [
                    for (final host in shown)
                      if (!live(host)) hostCard(host),
                  ]),
                  ('Databases', [
                    for (final db in databases)
                      if (_matches(
                        '${db.displayName(byId[db.hostId])} ${db.summary}',
                      ))
                        databaseCard(db),
                  ]),
                ].where((section) => section.$2.isNotEmpty).toList();
                if (sections.isEmpty) return _NoMatch(_search.text.trim());

                // Headed only once there is more than one: hosts alone read
                // as they always have.
                final headed = sections.length > 1;
                final items = [
                  for (final (title, cards) in sections) ...[
                    if (headed) _SectionHeader(title),
                    ...rows(cards),
                  ],
                ];
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 88),
                  itemCount: items.length,
                  itemBuilder: (context, i) => items[i],
                );
              },
            ),
    );
  }
}

/// The app's name and its tagline, as the header has always read them: the
/// prompt drawn before it and the mono face were too much, said of the first
/// build of this redesign.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  static const _tagline = 'Terminal buddy in your pocket';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Jeansh'),
        Text(
          _tagline,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Home's one add button. A tap stacks Host and Database above it; a second
/// tap, or a tap anywhere else, puts them away.
class _AddButton extends StatefulWidget {
  const _AddButton({required this.onHost, required this.onDatabase});

  final VoidCallback onHost;
  final VoidCallback onDatabase;

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton> {
  var _open = false;

  void _close() {
    if (_open) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      onTapOutside: (_) => _close(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_open)
            for (final (label, icon, onPressed) in [
              ('Database', Icons.storage, widget.onDatabase),
              ('Host', Icons.dns_outlined, widget.onHost),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: FloatingActionButton.extended(
                  // No hero: only the Add button stays on screen.
                  heroTag: null,
                  onPressed: () {
                    _close();
                    onPressed();
                  },
                  icon: Icon(icon),
                  label: Text(label),
                ),
              ),
          FloatingActionButton.extended(
            onPressed: () => setState(() => _open = !_open),
            icon: Icon(_open ? Icons.close : Icons.add),
            label: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Quiet: a heading is there to be read past, not at.
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Every card on Home: flat, on a hairline of the outline, its corners the
/// icon's softer ones.
ShapeBorder _cardShape(ColorScheme scheme) => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(16),
  side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .3)),
);

/// A card's badge with a line of small text under it, as wide on every card
/// so every name starts at the same x. The line is always a line's room, even
/// blank (an empty Text is a little shorter), so every badge sits as high.
class _BadgeColumn extends StatelessWidget {
  const _BadgeColumn({
    required this.badge,
    this.caption = '',
    this.live = false,
  });

  final Widget badge;
  final String caption;

  /// A shell up on this host: a lit dot cut into the badge's corner, which
  /// says it without a word.
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 80,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (live)
            Stack(
              clipBehavior: Clip.none,
              children: [
                badge,
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                      // Cut out of the badge in the card's own colour.
                      border: Border.all(
                        color:
                            theme.cardTheme.color ??
                            theme.colorScheme.surfaceContainerLow,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ],
            )
          else
            badge,
          const SizedBox(height: 4),
          DefaultTextStyle.merge(
            // A step under labelSmall's 11.
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 9.5,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                const ExcludeSemantics(child: Text(' ')),
                Text(caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A card's name and, under it, its address in the face machine text is
/// written in. Nothing else: the auth method, tmux and the jump host were a
/// line too many, and are in the host's own page.
class _CardText extends StatelessWidget {
  const _CardText({required this.name, required this.address});

  final String name;
  final String address;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        Text(
          address,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: uiMonoFamily,
            fontSize: 12.5,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _HostTile extends StatelessWidget {
  const _HostTile({
    required this.host,
    required this.sessionCount,
    required this.activeCount,
    required this.onOpen,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
    required this.onCloseSessions,
  });

  final HostProfile host;

  /// Every tab open on this host, connected or not.
  final int sessionCount;

  /// The ones with a shell actually attached.
  final int activeCount;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final VoidCallback onCloseSessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // By hand rather than a ListTile, whose leading is at most 56 dp tall:
    // too short for the badge with its version under it.
    return Card(
      margin: const EdgeInsets.all(6),
      elevation: 0,
      shape: _cardShape(theme.colorScheme),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 12, 4, 12),
          child: Row(
            children: [
              // Only the version under the badge: the badge already says
              // which OS, and a lit corner that a shell is up.
              _BadgeColumn(
                badge: OsBadge(host.os, size: 44),
                caption: host.os?.version ?? '',
                live: activeCount > 0,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CardText(
                  name: host.displayName,
                  address: host.target,
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (action) => switch (action) {
                  'edit' => onEdit(),
                  'duplicate' => onDuplicate(),
                  'delete' => onDelete(),
                  'close' => onCloseSessions(),
                  _ => null,
                },
                itemBuilder: (_) => [
                  if (sessionCount > 0)
                    PopupMenuItem(
                      value: 'close',
                      child: Text(
                        sessionCount == 1
                            ? 'Close session'
                            : 'Close $sessionCount sessions',
                      ),
                    ),
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  const PopupMenuItem(
                    value: 'duplicate',
                    child: Text('Duplicate'),
                  ),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A saved database, laid out as a host's card is: a tap opens it in a tab
/// of its own.
class _DatabaseTile extends StatelessWidget {
  const _DatabaseTile({
    required this.db,
    required this.host,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final DbConnection db;

  /// Null once its host was deleted.
  final HostProfile? host;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(6),
      elevation: 0,
      shape: _cardShape(Theme.of(context).colorScheme),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 12, 4, 12),
          child: Row(
            children: [
              _BadgeColumn(badge: DbBadge(db.kind, size: 44)),
              const SizedBox(width: 8),
              Expanded(
                child: _CardText(
                  name: db.displayName(host),
                  address: '${db.kind.label} · ${db.summary}',
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (action) => switch (action) {
                  'edit' => onEdit(),
                  'delete' => onDelete(),
                  _ => null,
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.terminal,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('No hosts yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add a host to open a shell on it.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A search that matched no host and no database.
class _NoMatch extends StatelessWidget {
  const _NoMatch(this.query);

  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Nothing matches “$query”',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
