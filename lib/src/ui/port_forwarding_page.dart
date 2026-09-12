import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../data/secret_store.dart';
import '../models/forward_setting.dart';
import '../models/host_profile.dart';
import '../models/port_snippets.dart';
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

/// The port forwarding settings: ports tunnelled between this tablet and a
/// saved host, either way, each setting over a connection of its own with no
/// terminal. Each is switched on and off here, and tapped to edit.
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
            for (final MapEntry(key: side, value: problem)
                in run.problems.entries)
              Text('$side: $problem', style: TextStyle(color: scheme.error)),
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
              'Add one to reach a host\'s port from this tablet, like a '
              'database app on 127.0.0.1, or to let the host reach a port on '
              'this tablet.',
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

enum _Direction { tabletToRemote, remoteToTablet }

/// One mapping's fields, as typed so far. A blank advanced field is its
/// default: the same port, and each side's own loopback.
class _Mapping {
  _Mapping([PortMapping? mapping]) {
    if (mapping is LocalForward) {
      port.text = '${mapping.localPort}';
      if (mapping.destHost != 'localhost') remoteHost.text = mapping.destHost;
      if (mapping.destPort != mapping.localPort) {
        otherPort.text = '${mapping.destPort}';
      }
    } else if (mapping is RemoteForward) {
      direction = _Direction.remoteToTablet;
      port.text = '${mapping.remotePort}';
      if (mapping.remoteHost != 'localhost') {
        listenHost.text = mapping.remoteHost;
      }
      if (mapping.tabletHost != '127.0.0.1') {
        tabletHost.text = mapping.tabletHost;
      }
      if (mapping.tabletPort != mapping.remotePort) {
        otherPort.text = '${mapping.tabletPort}';
      }
    }
    // What was set there shows.
    advanced = [
      remoteHost,
      listenHost,
      tabletHost,
      otherPort,
    ].any((field) => field.text.isNotEmpty);
  }

  var direction = _Direction.tabletToRemote;
  var advanced = false;

  /// The chip last tapped. The setting is named after it while [port]
  /// still holds its port.
  PortSnippet? snippet;

  /// Where connections start: on the tablet, or on the host.
  final port = TextEditingController();

  /// Tablet → Remote's destination, as the host reaches it.
  final remoteHost = TextEditingController();

  /// Remote → Tablet's address the host listens on, and its target as the
  /// tablet reaches it.
  final listenHost = TextEditingController();
  final tabletHost = TextEditingController();

  /// The far end's port, either way.
  final otherPort = TextEditingController();

  bool get tablet => direction == _Direction.tabletToRemote;

  /// What it forwards, once [port] is a number.
  PortMapping? get value {
    final port = int.tryParse(this.port.text.trim());
    if (port == null) return null;
    final other = int.tryParse(otherPort.text.trim()) ?? port;
    String or(TextEditingController field, String blank) =>
        field.text.trim().isEmpty ? blank : field.text.trim();
    return tablet
        ? LocalForward(
            localPort: port,
            destHost: or(remoteHost, 'localhost'),
            destPort: other,
          )
        : RemoteForward(
            remoteHost: or(listenHost, 'localhost'),
            remotePort: port,
            tabletHost: or(tabletHost, '127.0.0.1'),
            tabletPort: other,
          );
  }

  void dispose() {
    for (final field in [port, remoteHost, listenHost, tabletHost, otherPort]) {
      field.dispose();
    }
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
  static const _newHost = ' new';

  final _form = GlobalKey<FormState>();
  final _hostField = GlobalKey<FormFieldState<String>>();
  late final _hosts = [...widget.hosts];
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _mappings = [
    for (final mapping in widget.existing?.mappings ?? const <PortMapping>[])
      _Mapping(mapping),
    if (widget.existing?.mappings.isEmpty ?? true) _Mapping(),
  ];

  /// A host deleted since is no host at all.
  late String? _hostId = _hosts
      .where((host) => host.id == widget.existing?.hostId)
      .firstOrNull
      ?.id;

  /// The picked host's name, for the sentences.
  String get _hostName =>
      _hosts.where((host) => host.id == _hostId).firstOrNull?.displayName ??
      'the host';

  /// What a blank Name saves as: `PostgreSQL on db box`, while the first
  /// port is still the chip's it came from. Otherwise blank, which shows the
  /// host's name.
  String get _defaultName {
    final first = _mappings.first;
    final snippet = first.snippet;
    if (snippet == null ||
        _hostId == null ||
        int.tryParse(first.port.text.trim()) != snippet.port) {
      return '';
    }
    return '${snippet.name} on $_hostName';
  }

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
    final name = _name.text.trim();
    await widget.forwards.save(
      ForwardSetting(
        id: widget.existing?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        hostId: _hostId!,
        name: name.isEmpty ? _defaultName : name,
        mappings: [for (final mapping in _mappings) mapping.value!],
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

  /// Why [mapping]'s port cannot be, or null when it can: no two listen on
  /// one port on the same side.
  String? _portError(_Mapping mapping) {
    final error = PortMapping.portError(
      mapping.port.text,
      tablet: mapping.tablet,
    );
    if (error != null) return error;
    final side = mapping.value!.side;
    final twice = _mappings.where((other) => other.value?.side == side);
    return twice.length > 1 ? 'Used twice' : null;
  }

  /// A mapping's direction, port, service chips, what it does in words, and
  /// its advanced fields. [wide] puts the direction and port on one line.
  Widget _mappingBlock(_Mapping mapping, {required bool wide}) {
    final theme = Theme.of(context);
    final port = int.tryParse(mapping.port.text.trim());
    final sentence = mapping.value?.sentence(_hostName);

    final direction = SegmentedButton<_Direction>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: _Direction.tabletToRemote,
          label: Text('Tablet → Remote'),
        ),
        ButtonSegment(
          value: _Direction.remoteToTablet,
          label: Text('Remote → Tablet'),
        ),
      ],
      selected: {mapping.direction},
      onSelectionChanged: (picked) =>
          setState(() => mapping.direction = picked.single),
    );
    final portField = TextFormField(
      controller: mapping.port,
      decoration: InputDecoration(
        labelText: mapping.tablet ? 'Tablet port' : 'Remote port',
        helperText: !mapping.tablet && port != null && port > 0 && port < 1024
            ? 'Hosts usually refuse ports below 1024 unless you sign in as '
                  'root.'
            : null,
        helperMaxLines: 2,
        errorMaxLines: 4,
      ),
      keyboardType: TextInputType.number,
      validator: (_) => _portError(mapping),
      onChanged: (_) => setState(() {}),
    );
    final chips = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 8,
        children: [
          for (final snippet in portSnippets)
            ChoiceChip(
              label: Text('${snippet.name} ${snippet.port}'),
              selected: port == snippet.port,
              // The far end follows the port; its hosts stay as they are.
              onSelected: (_) => setState(() {
                mapping
                  ..port.text = '${snippet.port}'
                  ..otherPort.clear()
                  ..snippet = snippet;
              }),
            ),
        ],
      ),
    );

    return Card.outlined(
      key: ObjectKey(mapping),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 16,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: direction,
                  ),
                  Expanded(child: portField),
                ],
              )
            else ...[direction, const SizedBox(height: 8), portField],
            const SizedBox(height: 8),
            chips,
            const SizedBox(height: 12),
            Text(
              sentence ?? 'Type a port, or tap a service.',
              style: sentence == null
                  ? theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )
                  : theme.textTheme.bodyMedium,
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () =>
                      setState(() => mapping.advanced = !mapping.advanced),
                  icon: Icon(
                    mapping.advanced ? Icons.expand_less : Icons.expand_more,
                  ),
                  label: const Text('Advanced'),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Remove port',
                  onPressed: _mappings.length == 1
                      ? null
                      : () => _removeMapping(mapping),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
            if (mapping.advanced) ..._advanced(mapping),
          ],
        ),
      ),
    );
  }

  /// The far end, and for Remote → Tablet the address the host listens on.
  /// Blank is the default each hint shows.
  List<Widget> _advanced(_Mapping mapping) {
    final scheme = Theme.of(context).colorScheme;
    InputDecoration decoration(
      String label,
      String blank, {
      String? helper,
      Color? helperColor,
    }) => InputDecoration(
      labelText: label,
      hintText: blank,
      helperText: helper,
      helperStyle: helperColor == null ? null : TextStyle(color: helperColor),
      helperMaxLines: 3,
      errorMaxLines: 2,
      floatingLabelBehavior: FloatingLabelBehavior.always,
    );
    Widget host(TextEditingController field, InputDecoration decoration) =>
        TextFormField(
          controller: field,
          decoration: decoration,
          autocorrect: false,
          keyboardType: TextInputType.url,
          onChanged: (_) => setState(() {}),
        );
    Widget withPort(Widget host) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Expanded(flex: 3, child: host),
        Expanded(
          flex: 2,
          child: TextFormField(
            controller: mapping.otherPort,
            decoration: decoration(
              mapping.tablet ? 'Remote port' : 'Tablet port',
              'Same',
            ),
            keyboardType: TextInputType.number,
            validator: (value) => (value ?? '').trim().isEmpty
                ? null
                : PortMapping.portError(value),
            onChanged: (_) => setState(() {}),
          ),
        ),
      ],
    );

    if (mapping.tablet) {
      return [
        withPort(
          host(
            mapping.remoteHost,
            decoration(
              'Remote host',
              'localhost',
              helper: 'As the host reaches it: localhost is the host itself.',
            ),
          ),
        ),
      ];
    }
    final listen = mapping.listenHost.text.trim();
    final exposed = listen.isNotEmpty && !RemoteForward.loopback(listen);
    return [
      host(
        mapping.listenHost,
        decoration(
          'Remote listens on',
          'localhost',
          helper: exposed
              ? 'Open to the host\'s network too, and needs GatewayPorts in '
                    'its sshd_config.'
              : 'Only programs on the host itself can connect.',
          helperColor: exposed ? scheme.tertiary : null,
        ),
      ),
      const SizedBox(height: 8),
      withPort(host(mapping.tabletHost, decoration('Tablet host', '127.0.0.1'))),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defaultName = _defaultName;

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
                decoration: InputDecoration(
                  labelText: 'Name',
                  helperText:
                      'Optional. Defaults to '
                      '${defaultName.isEmpty ? 'the host\'s name' : defaultName}.',
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 24),
              Text('Ports', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'Pick which way each port goes, then the port.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              for (final mapping in _mappings)
                _mappingBlock(mapping, wide: constraints.maxWidth >= 600),
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
