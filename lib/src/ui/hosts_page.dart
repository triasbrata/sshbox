import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/host_repository.dart';
import '../data/secret_store.dart';
import '../models/host_profile.dart';
import '../session/session_manager.dart';
import 'host_edit_page.dart';
import 'os_icon.dart';
import 'settings_page.dart';

class HostsPage extends StatefulWidget {
  const HostsPage({
    super.key,
    required this.repository,
    required this.secrets,
    required this.sessions,
    required this.onOpenHost,
    required this.pushToken,
  });

  final HostRepository repository;
  final SecretStore secrets;
  final SessionManager sessions;

  /// Reads the current FCM registration token, so it can be copied out and
  /// handed to whatever server should be able to notify this device.
  final String? Function() pushToken;

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
        ),
      ),
    );
    // An open tab keeps the profile it was opened with; without this, a new
    // file tree root would wait for the tab to be closed and opened again.
    if (saved != null) widget.sessions.updateHost(saved);
    await _reload();
  }

  Future<void> _copyPushToken() async {
    final token = widget.pushToken();
    final messenger = ScaffoldMessenger.of(context);

    if (token == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No FCM token yet — push is unavailable')),
      );
      return;
    }

    await Clipboard.setData(ClipboardData(text: token));
    messenger.showSnackBar(
      const SnackBar(content: Text('FCM token copied')),
    );
  }

  Future<void> _confirmDelete(HostProfile host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${host.displayName}?'),
        content: const Text(
          'Every open session for this host is closed, and its saved password '
          'or private key is removed from the device keystore.',
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
    await widget.repository.delete(host.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _hosts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Clode'),
        actions: [
          IconButton(
            tooltip: 'Copy FCM token',
            onPressed: _copyPushToken,
            icon: const Icon(Icons.key_outlined),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
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
              // text at any font size. The cards' 6 dp margins make the rest
              // of the gutters.
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 88),
                itemCount: (hosts.length / columns).ceil(),
                itemBuilder: (context, row) => Row(
                  children: [
                    for (var i = row * columns; i < (row + 1) * columns; i++)
                      Expanded(
                        child: i < hosts.length
                            ? card(hosts[i])
                            : const SizedBox(),
                      ),
                  ],
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

    return Card(
      margin: const EdgeInsets.all(6),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Stack(
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
                    // Cut out of the icon in the card's own colour.
                    border: Border.all(
                      color: theme.cardTheme.color ??
                          theme.colorScheme.surfaceContainerLow,
                      width: 2,
                    ),
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          host.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // A line each, so a long address ellipsizes without taking the
        // session count with it on a narrow card.
        subtitle: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in [
              // As Termius puts it: `ssh, me, ubuntu`.
              ['ssh', host.username, ?host.os?.id]
                  .where((part) => part.isNotEmpty)
                  .join(', '),
              ?host.os?.summary,
              host.target,
              switch (activeCount) {
                0 => authLabel,
                1 => 'active session',
                _ => '$activeCount active sessions',
              },
            ])
              Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
        onTap: onOpen,
        trailing: PopupMenuButton<String>(
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
