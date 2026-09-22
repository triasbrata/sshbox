import 'dart:async';

import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../data/secret_store.dart';
import '../db/db_session.dart';
import '../models/host_profile.dart';
import '../platform.dart';
import '../session/local_transport.dart';
import '../session/port_forwards.dart';
import '../session/session_manager.dart';
import 'connect_sheet.dart';
import 'db_editor_page.dart';
import 'host_edit_page.dart';
import 'known_hosts_page.dart';
import 'logs_page.dart';
import 'os_icon.dart';
import 'port_forwarding_page.dart';
import 'settings_page.dart';
import 'tui.dart';
import 'update_dialog.dart';

class HostsPage extends StatefulWidget {
  const HostsPage({
    super.key,
    required this.repository,
    required this.secrets,
    required this.sessions,
    required this.onOpenHost,
    this.onOpenLocal,
    this.onOpenWsl,
    this.findWslDistros = wslDistros,
  });

  final HostRepository repository;
  final SecretStore secrets;
  final SessionManager sessions;

  /// Opens another session on the host, even one that already has some — the
  /// tab strip is how you get back to those.
  final Future<void> Function(String hostId) onOpenHost;

  /// Opens a shell on this machine — see `LocalTransport`. Null where there
  /// can be no such thing, which is every build but the desktop ones, and the
  /// card for it is then not drawn.
  final Future<void> Function()? onOpenLocal;

  /// Opens a shell in one of [findWslDistros]'s distros, each of which gets a
  /// card beside the local shell's. Only the Windows build hands one over.
  final Future<void> Function(String distro)? onOpenWsl;

  /// The WSL distros to draw cards for: [wslDistros], which finds none
  /// anywhere but Windows, unless a test brings its own.
  final Future<List<String>> Function() findWslDistros;

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  /// Whether this build can open a shell on the machine it runs on, and so
  /// whether Home shows a card for one. Both halves matter: only a desktop
  /// has a shell to open, and only a caller that handed [HostsPage.onOpenLocal]
  /// over can open it.
  bool get _local => isDesktop && widget.onOpenLocal != null;

  List<HostProfile>? _hosts;
  List<DbConnection>? _databases;

  /// Asked for once, as Home first shows: a distro installed while the app
  /// runs shows the next time it starts.
  List<String> _wsl = const [];

  @override
  void initState() {
    super.initState();
    _reload();
    widget.sessions.addListener(_onSessionsChanged);
    if (_local && widget.onOpenWsl != null) {
      unawaited(
        widget.findWslDistros().then((distros) {
          if (mounted) setState(() => _wsl = distros);
        }),
      );
    }
  }

  @override
  void dispose() {
    widget.sessions.removeListener(_onSessionsChanged);
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
    final confirmed = await showTuiConfirmDialog(
      context,
      title: 'delete host',
      message: 'Delete ${host.displayName}?',
      detail:
          'Every open session for this host is closed, its saved password or '
          'private key is removed from the device keystore, and its '
          'notification key is revoked.',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
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

  /// Under the app's name in the header.
  static const _tagline = 'Terminal buddy in your pocket';

  Future<void> _openPortForwarding() async {
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
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _hosts;
    final databases = _databases;
    // A desktop always has one thing to show, the local shell, so the
    // "add your first host" page would be standing in front of it.
    final empty =
        hosts != null &&
        databases != null &&
        hosts.isEmpty &&
        databases.isEmpty &&
        !_local;

    // termul's home_screen: its header, its empty state or its list, and its
    // add button along the bottom.
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _HomeHeader(
              actions: [
                // The way in when nothing is on its way: the tab joins the
                // strip by itself only as a transfer starts, so without this
                // the history of what was downloaded is out of reach.
                (
                  'Transfers',
                  Icons.swap_vert,
                  () => widget.sessions.showTransfers(select: true),
                ),
                ('Port forwarding', Icons.swap_horiz, _openPortForwarding),
                (
                  'Logs',
                  Icons.history,
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => LogsPage(
                        repository: widget.repository,
                        onOpenHost: widget.onOpenHost,
                      ),
                    ),
                  ),
                ),
                (
                  'Known hosts',
                  Icons.fingerprint,
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          KnownHostsPage(repository: widget.repository),
                    ),
                  ),
                ),
                (
                  'Settings',
                  Icons.settings_outlined,
                  () => openSettings(
                    Navigator.of(context),
                    notifyKeys: widget.sessions.notifyKeys,
                  ),
                ),
              ],
            ),
            Expanded(
              child: hosts == null || databases == null
                  // TODO(termul): progress indicator (gap 5).
                  ? const Center(child: CircularProgressIndicator())
                  : empty
                  ? const _EmptyState()
                  : _list(hosts, databases),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: _AddButton(
                onHost: () => _openEditor(),
                onDatabase: () => _editDatabase(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// termul's connection list: the page's title, how many there are, and a
  /// row each between hairlines — in columns once there is a tablet's width,
  /// the hosts in sections once there is more than hosts to tell apart.
  Widget _list(List<HostProfile> hosts, List<DbConnection> databases) {
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);

    Widget hostRow(HostProfile host) {
      final open = widget.sessions.sessionsFor(host.id);
      return HomeRow.host(
        host: host,
        sessionCount: open.length,
        activeCount: open.where((s) => s.isConnected).length,
        onOpen: () => widget.onOpenHost(host.id),
        onEdit: () => _openEditor(existing: host),
        onDuplicate: () => _duplicate(host),
        onDelete: () => _confirmDelete(host),
        onCloseSessions: () => widget.sessions.closeHost(host.id),
        // The way back to a session left running with Detach, with nothing
        // of the host open: a tap would make a new session first, only to
        // be closed again.
        onAttach: host.useTmux
            ? () => openInSheet(
                context,
                widget.sessions,
                host,
                secrets: widget.secrets,
                pickTmux: true,
              )
            : null,
      );
    }

    Widget databaseRow(DbConnection db) {
      final host = hosts.where((host) => host.id == db.hostId).firstOrNull;
      return HomeRow.database(
        db: db,
        host: host,
        onOpen: () => widget.sessions.openDb(db, db.displayName(host)),
        onEdit: () => _editDatabase(db),
        onDelete: () => _deleteDatabase(db),
      );
    }

    final machine = [
      if (_local) ...[
        HomeRow.local(
          sessions: widget.sessions.sessionsFor(localHostId),
          onOpen: () => widget.onOpenLocal!(),
        ),
        for (final distro in _wsl)
          HomeRow.local(
            title: distro,
            idle: 'A WSL shell',
            sessions: widget.sessions.sessionsFor(wslHost(distro).id),
            onOpen: () => widget.onOpenWsl!(distro),
          ),
      ],
    ];
    final hostRows = [for (final host in hosts) hostRow(host)];
    final databaseRows = [for (final db in databases) databaseRow(db)];
    // Headed only once there is something else to tell the hosts apart
    // from — a database, or this machine's own shell.
    final headed = databases.isNotEmpty || _local;

    String count(int n, String one) => '$n $one${n == 1 ? '' : 's'}';
    final counted = [
      if (machine.isNotEmpty) count(machine.length, 'local shell'),
      count(hosts.length, 'SSH connection'),
      if (databases.isNotEmpty) count(databases.length, 'database'),
    ].join(' · ');

    return LayoutBuilder(
      builder: (context, constraints) {
        // Material's compact breakpoint, as the tab strip uses: one column
        // on a phone, three once there is a tablet's width.
        final columns = constraints.maxWidth < 600 ? 1 : 3;

        // Rows of rows, so every row in a line is as tall as the tallest.
        List<Widget> grid(List<Widget> rows) => [
          for (var start = 0; start < rows.length; start += columns)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = start; i < start + columns; i++) ...[
                    if (i > start) const SizedBox(width: 24),
                    Expanded(
                      child: i < rows.length ? rows[i] : const SizedBox(),
                    ),
                  ],
                ],
              ),
            ),
        ];

        Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 4),
          child: TuiSectionLabel(title),
        );

        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          children: [
            Text(
              'Hosts',
              style: theme.textTheme.displayMedium!.copyWith(
                color: p.accent,
                fontSize: 36,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              counted,
              style: theme.textTheme.labelSmall!.copyWith(
                color: p.dim,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 8),
            Container(height: 1, color: p.border),
            if (machine.isNotEmpty) ...[
              if (hostRows.isNotEmpty || databaseRows.isNotEmpty)
                section('This machine'),
              ...grid(machine),
            ],
            if (hostRows.isNotEmpty) ...[
              if (headed) section('Hosts'),
              ...grid(hostRows),
            ],
            if (databaseRows.isNotEmpty) ...[
              section('Databases'),
              ...grid(databaseRows),
            ],
          ],
        );
      },
    );
  }
}

/// termul's home header: its mark and name, then the page's buttons — its
/// settings icon, and Jeansh's other ways off Home drawn the same.
class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.actions});

  final List<(String, IconData, VoidCallback)> actions;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 10, height: 10, color: p.deep),
              const SizedBox(width: 10),
              Semantics(
                container: true,
                label: 'Jeansh',
                header: true,
                excludeSemantics: true,
                child: Text(
                  'JEANSH',
                  style: theme.textTheme.labelSmall!.copyWith(
                    color: p.deep,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const Spacer(),
              for (final (tooltip, icon, onTap) in actions) ...[
                // Left of Settings, while a newer release is out.
                if (tooltip == 'Settings') const UpdateChip(),
                // TODO(termul): tooltip (gap 4).
                Tooltip(
                  message: tooltip,
                  child: Semantics(
                    container: true,
                    button: true,
                    label: tooltip,
                    child: GestureDetector(
                      onTap: onTap,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(icon, size: 20, color: p.accent),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _HostsPageState._tagline,
            style: theme.textTheme.labelSmall!.copyWith(color: p.dim),
          ),
        ],
      ),
    );
  }
}

/// Home's one add button, termul's: a tap stacks Host and Database above it;
/// a second tap, or a tap anywhere else, puts them away.
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_open)
            for (final (label, onPressed) in [
              ('Database', widget.onDatabase),
              ('Host', widget.onHost),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TuiButton(
                  label: label,
                  prefix: '▸',
                  variant: TuiButtonVariant.ghost,
                  onPressed: () {
                    _close();
                    onPressed();
                  },
                ),
              ),
          TuiButton(
            label: 'Add',
            prefix: _open ? '×' : '+',
            onPressed: () => setState(() => _open = !_open),
          ),
        ],
      ),
    );
  }
}

/// One thing on Home, as termul's home_screen draws a connection: its name
/// large in the accent with what a tap does beside it, where it goes under
/// it, and a line of how it stands. A host keeps Jeansh's OS badge at its
/// left and its menu at its right, termul having no component for either.
class HomeRow extends StatelessWidget {
  const HomeRow._({
    required this.title,
    required this.endpoint,
    required this.status,
    required this.verb,
    required this.onOpen,
    this.badge,
    this.live = false,
    this.menu = const [],
  });

  /// A saved host.
  factory HomeRow.host({
    required HostProfile host,
    required int sessionCount,
    required int activeCount,
    required VoidCallback onOpen,
    required VoidCallback onEdit,
    required VoidCallback onDuplicate,
    required VoidCallback onDelete,
    required VoidCallback onCloseSessions,
    VoidCallback? onAttach,
  }) {
    final auth = switch (host.authMethod) {
      SshAuthMethod.password => 'password',
      SshAuthMethod.privateKey => 'key',
      SshAuthMethod.tailscale => 'tailscale',
    };
    return HomeRow._(
      title: host.displayName,
      endpoint: host.target,
      status: switch (activeCount) {
        0 => [auth, if (host.useTmux) 'tmux'].join(' · '),
        1 => 'active session',
        _ => '$activeCount active sessions',
      },
      live: activeCount > 0,
      verb: 'connect',
      onOpen: onOpen,
      badge: _OsBadgeWithVersion(host: host, live: activeCount > 0),
      menu: [
        if (sessionCount > 0)
          (
            sessionCount == 1
                ? 'Close session'
                : 'Close $sessionCount sessions',
            onCloseSessions,
          ),
        if (onAttach != null) ('Attach to a tmux session…', onAttach),
        ('Edit', onEdit),
        ('Duplicate', onDuplicate),
        ('Delete', onDelete),
      ],
    );
  }

  /// A saved database.
  factory HomeRow.database({
    required DbConnection db,
    required HostProfile? host,
    required VoidCallback onOpen,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) => HomeRow._(
    title: db.displayName(host),
    endpoint: '${db.kind.label} · ${db.summary}',
    status: 'via ${host?.displayName ?? 'a deleted host'}',
    verb: 'open',
    onOpen: onOpen,
    badge: DbBadge(db.kind),
    menu: [('Edit', onEdit), ('Delete', onDelete)],
  );

  /// This machine's own shell, or a WSL distro's: no address, no
  /// credentials and nothing to edit. It counts the shells open on it, and a
  /// tap opens another — the tab strip is the way back to the ones up.
  factory HomeRow.local({
    required List<LiveSession> sessions,
    required VoidCallback onOpen,
    String title = 'Local shell',
    String idle = 'A shell on this machine',
  }) => HomeRow._(
    title: title,
    endpoint: idle,
    status: sessions.isEmpty ? '' : '${sessions.length} open',
    live: sessions.isNotEmpty,
    verb: 'open',
    onOpen: onOpen,
  );

  final String title;
  final String endpoint;
  final String status;
  final String verb;
  final VoidCallback onOpen;
  final Widget? badge;

  /// Something of it is running: its status in the accent.
  final bool live;
  final List<(String, VoidCallback)> menu;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);
    final small = theme.textTheme.labelSmall!;

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineMedium!.copyWith(
                  color: p.accent,
                  fontSize: 22,
                ),
              ),
            ),
            ExcludeSemantics(
              child: Text(
                verb.toUpperCase(),
                style: small.copyWith(color: p.accent, letterSpacing: 0.4),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Not in capitals, as termul draws its host:port: here it carries
        // the login, and a username is case-sensitive.
        Text(
          endpoint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: small.copyWith(color: p.dim, letterSpacing: 0.4),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Semantics(
                label: status,
                excludeSemantics: true,
                child: Text(
                  status.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: small.copyWith(
                    color: live ? p.accent : p.muted,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (badge case final badge?) ...[
                badge,
                const SizedBox(width: 16),
              ],
              Expanded(child: text),
              if (menu.isNotEmpty)
                // TODO(termul): popup / context menu (gap 3).
                PopupMenuButton<String>(
                  iconColor: p.dim,
                  onSelected: (label) =>
                      menu.firstWhere((item) => item.$1 == label).$2(),
                  itemBuilder: (_) => [
                    for (final (label, _) in menu)
                      PopupMenuItem(value: label, child: Text(label)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A host's OS logo with its version under it and a dot while a session is
/// up. TODO(termul): OS / brand logo badge (gap 18); Jeansh's own until then.
class _OsBadgeWithVersion extends StatelessWidget {
  const _OsBadgeWithVersion({required this.host, required this.live});

  final HostProfile host;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);
    // As wide on every row, so every name starts at the same x.
    return SizedBox(
      width: 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              OsBadge(host.os),
              if (live)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: p.accent,
                      // Cut out of the icon in the page's own colour.
                      border: Border.all(color: p.bg, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // Only the version: the badge already says which OS. Always a
          // line's room, even blank before the first connect or with no
          // version, so every badge sits as high.
          DefaultTextStyle.merge(
            style: theme.textTheme.labelSmall!.copyWith(color: p.dim),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                const ExcludeSemantics(child: Text(' ')),
                Text(host.os?.version ?? ''),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A fresh install's Home, termul's own empty home: the page says there is
/// nothing yet and what Jeansh is for, over the accent block for a first
/// connection; the add button sits under it along the bottom.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'No hosts\nyet',
            style: theme.textTheme.displayMedium!.copyWith(color: p.accent),
          ),
          const SizedBox(height: 16),
          Text(
            'Save a server once and open a shell on it with one tap. Jeansh '
            'signs in with a password, a private key or Tailscale.',
            style: theme.textTheme.titleMedium!.copyWith(
              color: p.text,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 32),
          Container(
            width: double.infinity,
            color: p.accent,
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FIRST CONNECTION',
                  style: theme.textTheme.labelSmall!.copyWith(
                    color: p.isLight ? p.panel : p.bg,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Tap Add, then Host, and fill in the address, port, '
                  'username and how you sign in. Your shells run on that '
                  'machine, and Jeansh keeps them open in tabs.',
                  style: theme.textTheme.bodyMedium!.copyWith(
                    color: p.isLight ? p.panel : p.bg,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
