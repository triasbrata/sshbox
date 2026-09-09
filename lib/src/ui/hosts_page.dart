import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/host_repository.dart';
import '../data/secret_store.dart';
import '../models/host_profile.dart';
import '../session/session_manager.dart';
import 'host_edit_page.dart';

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

  /// Routed through the app shell so a tap here and a notification tap take
  /// the identical path.
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

  void _onSessionsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    final hosts = await widget.repository.load();
    if (!mounted) return;
    setState(() => _hosts = hosts);
  }

  Future<void> _openEditor({HostProfile? existing}) async {
    await Navigator.of(context).push<HostProfile>(
      MaterialPageRoute(
        builder: (_) => HostEditPage(
          repository: widget.repository,
          secrets: widget.secrets,
          existing: existing,
        ),
      ),
    );
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
          'Any open session for this host is closed, and its saved password '
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
    await widget.sessions.close(host.id);
    await widget.repository.delete(host.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _hosts;
    final liveCount = widget.sessions.liveCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('sshbox'),
        actions: [
          IconButton(
            tooltip: 'Copy FCM token',
            onPressed: _copyPushToken,
            icon: const Icon(Icons.key_outlined),
          ),
        ],
        bottom: liveCount == 0
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      '$liveCount session${liveCount == 1 ? '' : 's'} open',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ),
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('Host'),
      ),
      body: switch (hosts) {
        null => const Center(child: CircularProgressIndicator()),
        [] => const _EmptyState(),
        _ => ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: hosts.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final host = hosts[index];
              return _HostTile(
                host: host,
                connected: widget.sessions.isConnected(host.id),
                hasSession: widget.sessions.hasSession(host.id),
                onOpen: () => widget.onOpenHost(host.id),
                onEdit: () => _openEditor(existing: host),
                onDelete: () => _confirmDelete(host),
                onCloseSession: () => widget.sessions.close(host.id),
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
    required this.connected,
    required this.hasSession,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
    required this.onCloseSession,
  });

  final HostProfile host;
  final bool connected;
  final bool hasSession;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onCloseSession;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authLabel = switch (host.authMethod) {
      SshAuthMethod.password => 'password',
      SshAuthMethod.privateKey => 'key',
      SshAuthMethod.tailscale => 'tailscale',
    };

    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.dns_outlined),
          if (connected)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.colorScheme.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Text(host.displayName),
      subtitle: Text(
        connected
            ? '${host.target}  ·  session open'
            : '${host.target}  ·  $authLabel',
      ),
      onTap: onOpen,
      trailing: PopupMenuButton<String>(
        onSelected: (action) => switch (action) {
          'edit' => onEdit(),
          'delete' => onDelete(),
          'close' => onCloseSession(),
          _ => null,
        },
        itemBuilder: (_) => [
          if (hasSession)
            const PopupMenuItem(value: 'close', child: Text('Close session')),
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
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
