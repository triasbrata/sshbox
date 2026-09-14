import 'dart:async';

import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../data/secret_store.dart';
import '../models/host_profile.dart';
import '../session/port_forwards.dart';
import '../session/session_manager.dart';
import 'databases_page.dart';
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

  @override
  void initState() {
    super.initState();
    _reload();
    widget.sessions.addListener(_onSessionsChanged);
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
    if (!mounted) return;
    setState(() => _hosts = hosts);
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
    // Not waited for: the relay may be slow or out of reach, and the key is
    // dropped either way.
    unawaited(widget.sessions.notifyKeys?.revoke(host.id));
    await widget.repository.delete(host.id);
    await _reload();
  }

  /// Under the app's name in the header.
  static const _tagline = 'Terminal buddy in your pocket';

  @override
  Widget build(BuildContext context) {
    final hosts = _hosts;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
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
        ),
        actions: [
          IconButton(
            tooltip: 'Databases',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DatabasesPage(
                  repository: widget.repository,
                  secrets: widget.secrets,
                ),
              ),
            ),
            icon: const Icon(Icons.storage),
          ),
          IconButton(
            tooltip: 'Port forwarding',
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
            icon: const Icon(Icons.swap_horiz),
          ),
          IconButton(
            tooltip: 'Logs',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LogsPage(
                  repository: widget.repository,
                  onOpenHost: widget.onOpenHost,
                ),
              ),
            ),
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: 'Known hosts',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => KnownHostsPage(repository: widget.repository),
              ),
            ),
            icon: const Icon(Icons.fingerprint),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    SettingsPage(notifyKeys: widget.sessions.notifyKeys),
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('Host'),
      ),
      body: switch (hosts) {
        null => const Center(child: CircularProgressIndicator()),
        [] => const _EmptyState(),
        _ => LayoutBuilder(
          builder: (context, constraints) {
            // Material's compact breakpoint, as the tab strip uses: one
            // column on a phone, three once there is a tablet's width.
            final columns = constraints.maxWidth < 600 ? 1 : 3;

            Widget card(HostProfile host) {
              final open = widget.sessions.sessionsFor(host.id);
              return _HostTile(
                host: host,
                sessionCount: open.length,
                activeCount: open.where((s) => s.isConnected).length,
                onOpen: () => widget.onOpenHost(host.id),
                onEdit: () => _openEditor(existing: host),
                onDelete: () => _confirmDelete(host),
                onCloseSessions: () => widget.sessions.closeHost(host.id),
              );
            }

            // Rows of cards rather than a grid, so a card is as tall as its
            // text at any font size, and every card in a row as tall as
            // the tallest. The cards' 6 dp margins make the rest of the
            // gutters.
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 88),
              itemCount: (hosts.length / columns).ceil(),
              itemBuilder: (context, row) => IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = row * columns; i < (row + 1) * columns; i++)
                      Expanded(
                        child: i < hosts.length
                            ? card(hosts[i])
                            : const SizedBox(),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      },
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
    final muted = theme.colorScheme.onSurfaceVariant;

    // By hand rather than a ListTile, whose leading is at most 56 dp tall:
    // too short for the badge with its version under it.
    return Card(
      margin: const EdgeInsets.all(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 12, 8, 12),
          child: Row(
            children: [
              // As wide on every card, so every name starts at the same x.
              SizedBox(
                width: 80,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        OsBadge(host.os),
                        if (activeCount > 0)
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                shape: BoxShape.circle,
                                // Cut out of the icon in the card's own
                                // colour.
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
                    ),
                    const SizedBox(height: 4),
                    // Only the version: the badge already says which OS.
                    // Always a line's room, even blank before the first
                    // connect or with no version (an empty Text is a little
                    // shorter), so every badge sits as high.
                    DefaultTextStyle.merge(
                      // A step under labelSmall's 11.
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: muted,
                        fontSize: 9.5,
                      ),
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
              ),
              const SizedBox(width: 8),
              // A line each, so a long address ellipsizes without taking the
              // session count with it on a narrow card.
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      host.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    for (final line in [
                      host.target,
                      switch (activeCount) {
                        0 => authLabel,
                        1 => 'active session',
                        _ => '$activeCount active sessions',
                      },
                    ])
                      Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: muted,
                        ),
                      ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (action) => switch (action) {
                  'edit' => onEdit(),
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
