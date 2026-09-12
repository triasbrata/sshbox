import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../data/secret_store.dart';
import '../models/forward_setting.dart';
import '../models/host_profile.dart';
import '../session/port_forwards.dart';
import 'host_edit_page.dart';
import 'os_icon.dart';
import 'terminal_page.dart' show openUrl;

/// Side padding that keeps a page's column readable on a tablet: 16 dp on a
/// phone, and a 720 dp column in the middle of anything wider.
EdgeInsets _gutters(double width, {double bottom = 32}) {
  final side = math.max(16.0, (width - 720) / 2);
  return EdgeInsets.fromLTRB(side, 8, side, bottom);
}

/// The port forwarding settings: ports on this tablet tunnelled to a saved
/// host, each over a connection of its own with no terminal. Each is
/// switched on and off here, and tapped to edit.
class PortForwardingPage extends StatefulWidget {
  const PortForwardingPage({
    super.key,
    required this.forwards,
    required this.repository,
    required this.secrets,
  });

  final PortForwards forwards;
  final HostRepository repository;
  final SecretStore secrets;

  @override
  State<PortForwardingPage> createState() => _PortForwardingPageState();
}

class _PortForwardingPageState extends State<PortForwardingPage> {
  /// Every saved host, for each setting's badge and name, once read.
  List<HostProfile>? _hosts;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final hosts = await widget.repository.load();
    if (mounted) setState(() => _hosts = hosts);
  }

  Future<void> _edit(List<HostProfile> hosts, [ForwardSetting? existing]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ForwardEditor(
          forwards: widget.forwards,
          repository: widget.repository,
          secrets: widget.secrets,
          hosts: hosts,
          existing: existing,
        ),
      ),
    );
    // A host made there has a badge and a name to show here.
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _hosts;

    return Scaffold(
      appBar: AppBar(title: const Text('Port forwarding')),
      floatingActionButton: hosts == null
          ? null
          : FloatingActionButton(
              tooltip: 'Add port forward',
              onPressed: () => _edit(hosts),
              child: const Icon(Icons.add),
            ),
      body: hosts == null
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: widget.forwards,
              builder: (context, _) {
                final runs = widget.forwards.runs;
                if (runs.isEmpty) return const _EmptyState();
                return LayoutBuilder(
                  builder: (context, constraints) => ListView(
                    padding: _gutters(constraints.maxWidth, bottom: 88),
                    children: [
                      for (final run in runs)
                        _ForwardCard(
                          run: run,
                          host: hosts
                              .where((host) => host.id == run.setting.hostId)
                              .firstOrNull,
                          onTap: () => _edit(hosts, run.setting),
                          onSwitch: (on) => unawaited(
                            on
                                ? widget.forwards.start(run.setting.id)
                                : widget.forwards.stop(run.setting.id),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _ForwardCard extends StatelessWidget {
  const _ForwardCard({
    required this.run,
    required this.host,
    required this.onTap,
    required this.onSwitch,
  });

  final ForwardRun run;

  /// Null once its host was deleted.
  final HostProfile? host;
  final VoidCallback onTap;
  final ValueChanged<bool> onSwitch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (status, color) = switch (run.status) {
      ForwardStatus.stopped => ('Stopped', scheme.onSurfaceVariant),
      ForwardStatus.connecting => ('Connecting…', scheme.onSurfaceVariant),
      ForwardStatus.running => ('Running', scheme.primary),
      ForwardStatus.reconnecting => ('Reconnecting…', scheme.tertiary),
      ForwardStatus.error => ('Error', scheme.error),
    };
    final error = run.error;
    final signIn = run.signIn;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: OsBadge(host?.os),
        title: Text(
          run.setting.displayName(host),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(run.setting.summary),
            Text(
              error == null ? status : '$status — $error',
              style: TextStyle(color: color),
            ),
            for (final MapEntry(key: port, value: problem)
                in run.problems.entries)
              Text('$port: $problem', style: TextStyle(color: scheme.error)),
            if (signIn != null)
              TextButton.icon(
                onPressed: () => openUrl(context, signIn),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Sign in to continue'),
              ),
          ],
        ),
        trailing: Switch(value: run.on, onChanged: onSwitch),
        onTap: onTap,
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
              Icons.swap_horiz,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('No port forwards yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add one to open a host\'s ports on this tablet, like ssh -L: a '
              'database app then connects to 127.0.0.1.',
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

/// One mapping's fields, as typed so far.
class _Mapping {
  _Mapping([LocalForward? mapping])
    : local = TextEditingController(text: '${mapping?.localPort ?? ''}'),
      host = TextEditingController(text: mapping?.destHost ?? 'localhost'),
      port = TextEditingController(text: '${mapping?.destPort ?? ''}');

  final TextEditingController local;
  final TextEditingController host;
  final TextEditingController port;

  /// A blank destination port is the tablet's: 5432 to the host's 5432.
  LocalForward get value {
    final localPort = int.parse(local.text.trim());
    return LocalForward(
      localPort: localPort,
      destHost: host.text.trim(),
      destPort: int.tryParse(port.text.trim()) ?? localPort,
    );
  }

  void dispose() {
    local.dispose();
    host.dispose();
    port.dispose();
  }
}

class _ForwardEditor extends StatefulWidget {
  const _ForwardEditor({
    required this.forwards,
    required this.repository,
    required this.secrets,
    required this.hosts,
    this.existing,
  });

  final PortForwards forwards;
  final HostRepository repository;
  final SecretStore secrets;
  final List<HostProfile> hosts;

  /// Null when adding one.
  final ForwardSetting? existing;

  @override
  State<_ForwardEditor> createState() => _ForwardEditorState();
}

class _ForwardEditorState extends State<_ForwardEditor> {
  /// The host list's "New host…" item.
  static const _newHost = ' new';

  final _form = GlobalKey<FormState>();
  final _hostField = GlobalKey<FormFieldState<String>>();
  late final _hosts = [...widget.hosts];
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _mappings = [
    for (final mapping in widget.existing?.mappings ?? const <LocalForward>[])
      _Mapping(mapping),
    if (widget.existing?.mappings.isEmpty ?? true) _Mapping(),
  ];

  /// A host deleted since is no host at all.
  late String? _hostId = _hosts
      .where((host) => host.id == widget.existing?.hostId)
      .firstOrNull
      ?.id;

  @override
  void dispose() {
    _name.dispose();
    for (final mapping in _mappings) {
      mapping.dispose();
    }
    super.dispose();
  }

  /// The host editor, for a host to forward to that is not saved yet. The
  /// one it saves comes back picked.
  Future<void> _addHost() async {
    final created = await Navigator.of(context).push<HostProfile>(
      MaterialPageRoute(
        builder: (_) => HostEditPage(
          repository: widget.repository,
          secrets: widget.secrets,
        ),
      ),
    );
    if (!mounted) return;
    if (created != null) {
      setState(() {
        _hosts.add(created);
        _hostId = created.id;
      });
    }
    _hostField.currentState!.didChange(_hostId);
  }

  void _removeMapping(_Mapping mapping) {
    setState(() => _mappings.remove(mapping));
    // Once its fields have gone with this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => mapping.dispose());
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    await widget.forwards.save(
      ForwardSetting(
        id: widget.existing?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        hostId: _hostId!,
        name: _name.text.trim(),
        mappings: [for (final mapping in _mappings) mapping.value],
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this port forward?'),
        content: const Text('If it is on, its ports close now.'),
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
    await widget.forwards.delete(widget.existing!.id);
    if (mounted) Navigator.of(context).pop();
  }

  /// Why [mapping]'s tablet port cannot be, or null when it can.
  String? _localPortError(_Mapping mapping) {
    final error = LocalForward.portError(mapping.local.text, local: true);
    if (error != null) return error;
    final port = int.parse(mapping.local.text.trim());
    final twice = _mappings.where(
      (other) => int.tryParse(other.local.text.trim()) == port,
    );
    return twice.length > 1 ? 'Used twice' : null;
  }

  Widget _mappingRow(_Mapping mapping) => Padding(
    key: ObjectKey(mapping),
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: TextFormField(
            controller: mapping.local,
            decoration: const InputDecoration(
              labelText: 'Tablet port',
              hintText: '5432',
              errorMaxLines: 4,
            ),
            keyboardType: TextInputType.number,
            validator: (_) => _localPortError(mapping),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: TextFormField(
            controller: mapping.host,
            decoration: const InputDecoration(labelText: 'To host'),
            autocorrect: false,
            keyboardType: TextInputType.url,
            validator: (value) => (value ?? '').trim().isEmpty
                ? 'A hostname or IP is required'
                : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextFormField(
            controller: mapping.port,
            decoration: const InputDecoration(
              labelText: 'To port',
              hintText: 'Same',
              errorMaxLines: 2,
            ),
            keyboardType: TextInputType.number,
            validator: (value) => (value ?? '').trim().isEmpty
                ? null
                : LocalForward.portError(value),
          ),
        ),
        IconButton(
          tooltip: 'Remove port',
          onPressed: _mappings.length == 1
              ? null
              : () => _removeMapping(mapping),
          icon: const Icon(Icons.remove_circle_outline),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existing == null ? 'New port forward' : 'Edit port forward',
        ),
        actions: [
          if (widget.existing != null)
            IconButton(
              tooltip: 'Delete',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          IconButton(
            tooltip: 'Save',
            onPressed: _save,
            icon: const Icon(Icons.check),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            padding: _gutters(constraints.maxWidth),
            children: [
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: _hostField,
                initialValue: _hostId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Host',
                  helperText: 'Reached as a terminal session reaches it, '
                      'through its jump host too.',
                  helperMaxLines: 2,
                ),
                items: [
                  for (final host in _hosts)
                    DropdownMenuItem(
                      value: host.id,
                      child: Row(
                        children: [
                          OsBadge(host.os, size: 24),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              host.displayName,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const DropdownMenuItem(
                    value: _newHost,
                    child: Row(
                      children: [
                        Icon(Icons.add),
                        SizedBox(width: 12),
                        Text('New host…'),
                      ],
                    ),
                  ),
                ],
                validator: (value) =>
                    value == null || value == _newHost ? 'Pick a host' : null,
                onChanged: (id) {
                  if (id == _newHost) {
                    unawaited(_addHost());
                  } else {
                    setState(() => _hostId = id);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'Optional. Defaults to the host\'s name.',
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 24),
              Text('Ports', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'Each tablet port opens on 127.0.0.1, for apps on this tablet '
                'only, and goes to the host and port as the SSH host reaches '
                'them: localhost is the SSH host itself. Android keeps ports '
                'below 1024 from apps.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              for (final mapping in _mappings) _mappingRow(mapping),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => setState(() => _mappings.add(_Mapping())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add port'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
