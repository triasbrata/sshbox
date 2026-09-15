import 'dart:async';
import 'dart:math' as math;

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

  /// The ways out of Home, each with its name on it rather than an icon to
  /// guess from, under the stitching: in a row that scrolls on a phone.
  PreferredSizeWidget _tools() {
    void push(Widget page) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));

    return PreferredSize(
      preferredSize: const Size.fromHeight(64),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: _Stitch(),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                // With how many run, which is why the page is opened most.
                ListenableBuilder(
                  listenable: portForwards,
                  builder: (context, _) => _Tool(
                    icon: Icons.swap_horiz,
                    label: 'Port forwarding',
                    count: portForwards.onCount,
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PortForwardingPage(
                            forwards: portForwards,
                            repository: widget.repository,
                            secrets: widget.secrets,
                          ),
                        ),
                      );
                      // A host made there belongs here too.
                      await _reload();
                    },
                  ),
                ),
                // The way in when nothing is on its way: the tab joins the
                // strip by itself only as a transfer starts, so without this
                // the history of what was downloaded is out of reach.
                _Tool(
                  icon: Icons.swap_vert,
                  label: 'Transfers',
                  onPressed: () => widget.sessions.showTransfers(select: true),
                ),
                _Tool(
                  icon: Icons.history,
                  label: 'Logs',
                  onPressed: () => push(
                    LogsPage(
                      repository: widget.repository,
                      onOpenHost: widget.onOpenHost,
                    ),
                  ),
                ),
                _Tool(
                  icon: Icons.fingerprint,
                  label: 'Known hosts',
                  onPressed: () =>
                      push(KnownHostsPage(repository: widget.repository)),
                ),
                _Tool(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  onPressed: () =>
                      push(SettingsPage(notifyKeys: widget.sessions.notifyKeys)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
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
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: SizedBox(width: 320, child: _searchField()),
            )
          else
            IconButton(
              tooltip: _searching ? 'Close search' : 'Search',
              onPressed: _toggleSearch,
              icon: Icon(_searching ? Icons.close : Icons.search),
            ),
        ],
        bottom: _tools(),
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
                    jumpHost: byId[host.jumpHostId]?.displayName,
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

/// The app's name as its icon writes it, the prompt in green before it, in
/// the face the app writes machine text in, and its tagline under it.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  static const _tagline = 'Terminal buddy in your pocket';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const mono = TextStyle(fontFamily: uiMonoFamily, fontWeight: FontWeight.w700);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Text(
                '>_',
                style: mono.copyWith(color: theme.colorScheme.primary),
              ),
            ),
            const SizedBox(width: 8),
            const Text('Jeansh', style: mono),
          ],
        ),
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

/// The stitching round the pocket on Jeansh's icon, drawn once, under Home's
/// name: the one place the app wears it.
class _Stitch extends StatelessWidget {
  const _Stitch();

  /// The thread's colour on the icon.
  static const _thread = Color(0xFFD6A25A);

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 2,
    width: double.infinity,
    child: CustomPaint(painter: _StitchPainter(_thread)),
  );
}

class _StitchPainter extends CustomPainter {
  const _StitchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: 0.6);
    for (var x = 0.0; x < size.width; x += 14) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, math.min(8, size.width - x), size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_StitchPainter oldDelegate) => oldDelegate.color != color;
}

/// A way out of Home, named: an outlined pill, with how many of the thing
/// run beside the name when [count] is more than none.
class _Tool extends StatelessWidget {
  const _Tool({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.count = 0,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (count > 0) ...[
              const SizedBox(width: 8),
              _Pill('$count on'),
            ],
          ],
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          backgroundColor: scheme.surfaceContainerHigh,
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .4)),
          minimumSize: const Size(0, 40),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 16, 0),
        ),
      ),
    );
  }
}

/// A count in the accent, on a faint wash of it: a host's live shells, or
/// the port forwards that run.
class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.dot = false});

  final String text;

  /// A lit dot before it, as a live shell's tab wears one.
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: primary, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(
              fontFamily: uiMonoFamily,
              fontSize: 11.5,
              height: 1,
              fontWeight: FontWeight.w600,
              color: primary,
            ),
          ),
        ],
      ),
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

    // In the accent, as Settings heads its sections.
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
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
  const _BadgeColumn({required this.badge, this.caption = ''});

  final Widget badge;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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

/// A card's name, its address in the face machine text is written in, and a
/// line of what else there is to know, each item cut short on its own.
class _CardText extends StatelessWidget {
  const _CardText({
    required this.name,
    required this.address,
    required this.details,
    this.pill,
  });

  final String name;
  final String address;
  final List<String> details;

  /// Beside the name: how many shells a host has up.
  final Widget? pill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final mono = TextStyle(fontFamily: uiMonoFamily, color: muted);
    final pill = this.pill;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (pill != null) ...[const SizedBox(width: 8), pill],
          ],
        ),
        Text(
          address,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.merge(mono).copyWith(
            fontSize: 12.5,
          ),
        ),
        const SizedBox(height: 4),
        // Kept apart by drawn dots rather than a character, so a detail can
        // be cut short without taking the others with it.
        Row(
          children: [
            for (final (i, detail) in details.indexed) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Container(
                    width: 3,
                    height: 3,
                    decoration: BoxDecoration(
                      color: muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              Flexible(
                child: Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.merge(mono),
                ),
              ),
            ],
          ],
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
    required this.jumpHost,
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

  /// The name of the saved host this one is reached through, if any.
  final String? jumpHost;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final VoidCallback onCloseSessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authLabel = switch (host.authMethod) {
      SshAuthMethod.password => 'password',
      SshAuthMethod.privateKey => 'key',
      SshAuthMethod.tailscale => 'tailscale',
    };
    final via = jumpHost;

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
              // which OS.
              _BadgeColumn(
                badge: OsBadge(host.os, size: 44),
                caption: host.os?.version ?? '',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CardText(
                  name: host.displayName,
                  address: host.target,
                  details: [
                    authLabel,
                    if (host.useTmux) 'tmux',
                    if (via != null) 'via $via',
                  ],
                  pill: activeCount > 0
                      ? _Pill('$activeCount active', dot: true)
                      : null,
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
                  details: ['via ${host?.displayName ?? 'a deleted host'}'],
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
