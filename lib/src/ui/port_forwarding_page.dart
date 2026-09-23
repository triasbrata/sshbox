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
import 'tui.dart';

/// Side padding that keeps a page's column readable on a tablet: 16 dp on a
/// phone, and a 720 dp column in the middle of anything wider.
EdgeInsets pageGutters(double width, {double bottom = 32}) {
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

  Future<void> _edit(
    List<HostProfile> hosts, [
    ForwardSetting? existing,
  ]) async {
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
      appBar: TuiAppBar(title: const Text('Port forwarding')),
      // termul's Add, where Home keeps its own.
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: hosts == null
          ? null
          : TuiButton(
              label: 'Add port forward',
              prefix: '+',
              onPressed: () => _edit(hosts),
            ),
      body: hosts == null
          ? const Center(child: TuiSpinner())
          : ListenableBuilder(
              listenable: widget.forwards,
              builder: (context, _) {
                final runs = widget.forwards.runs;
                if (runs.isEmpty) return const _EmptyState();
                return LayoutBuilder(
                  builder: (context, constraints) => ListView(
                    padding: pageGutters(constraints.maxWidth, bottom: 88),
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
    final pal = TermulThemeData.of(context).palette;
    final (status, color) = switch (run.status) {
      ForwardStatus.stopped => ('Stopped', pal.dim),
      ForwardStatus.connecting => ('Connecting…', pal.dim),
      ForwardStatus.running => ('Running', pal.accent),
      ForwardStatus.reconnecting => ('Reconnecting…', pal.yellow),
      ForwardStatus.error => ('Error', pal.red),
    };
    final error = run.error;
    final signIn = run.signIn;

    final p = TermulThemeData.of(context).palette;
    final text = Theme.of(context).textTheme;
    // A row as Home's are: its host's badge, its name large, what it does
    // and how it is going under it, and termul's switch.
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OsBadge(host?.os),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    run.setting.displayName(host),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium!.copyWith(color: p.accent),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    run.setting.summary,
                    style: text.bodySmall!.copyWith(color: p.dim),
                  ),
                  Text(
                    error == null ? status : '$status — $error',
                    style: text.bodySmall!.copyWith(color: color),
                  ),
                  for (final MapEntry(key: side, value: problem)
                      in run.problems.entries)
                    Text(
                      '$side: $problem',
                      style: text.bodySmall!.copyWith(color: p.red),
                    ),
                  if (signIn != null)
                    TermulTextAction(
                      label: 'Sign in to continue',
                      text: 'SIGN IN TO CONTINUE ↗',
                      onTap: () => openUrl(context, signIn),
                    ),
                ],
              ),
            ),
            TuiSwitch(value: run.on, onChanged: onSwitch),
          ],
        ),
      ),
    );
  }
}

// TODO(termul): empty state, until termul has one.
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
              'Reach a server\'s port from this device, like a database on '
              '127.0.0.1:5432, or let the server reach a port here.',
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

/// One mapping's fields, as typed so far. The advanced ones hold their
/// defaults until changed: the same port, and each side's own loopback. One
/// cleared still means its default.
class _Mapping {
  _Mapping([PortMapping? mapping]) {
    if (mapping is LocalForward) {
      port.text = '${mapping.localPort}';
      remoteHost.text = mapping.destHost;
      otherPort.text = '${mapping.destPort}';
    } else if (mapping is RemoteForward) {
      direction = _Direction.remoteToTablet;
      port.text = '${mapping.remotePort}';
      listenHost.text = mapping.remoteHost;
      tabletHost.text = mapping.tabletHost;
      otherPort.text = '${mapping.tabletPort}';
    }
    linked = otherPort.text == port.text;
    // What was set there shows.
    advanced =
        !linked ||
        remoteHost.text != 'localhost' ||
        listenHost.text != 'localhost' ||
        tabletHost.text != '127.0.0.1';
  }

  var direction = _Direction.tabletToRemote;
  var advanced = false;

  /// Whether [otherPort] follows [port] as it is typed: until the user types
  /// a far port of their own.
  var linked = true;

  /// The chip last tapped. The setting is named after it while [port]
  /// still holds its port.
  PortSnippet? snippet;

  /// Where connections start: on the tablet, or on the host.
  final port = TextEditingController();

  /// Tablet → Remote's destination, as the host reaches it.
  final remoteHost = TextEditingController(text: 'localhost');

  /// Remote → Tablet's address the host listens on, and its target as the
  /// tablet reaches it.
  final listenHost = TextEditingController(text: 'localhost');
  final tabletHost = TextEditingController(text: '127.0.0.1');

  /// The far end's port, either way.
  final otherPort = TextEditingController();

  bool get tablet => direction == _Direction.tabletToRemote;

  /// The far port back on [port], following it again, and each blank host
  /// its default: after a chip or a direction. A host typed here stays.
  void reset() {
    otherPort.text = port.text;
    linked = true;
    for (final (field, blank) in [
      (remoteHost, 'localhost'),
      (listenHost, 'localhost'),
      (tabletHost, '127.0.0.1'),
    ]) {
      if (field.text.trim().isEmpty) field.text = blank;
    }
  }

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
    // Every field is built, scrolled off or not, so none escapes this; the
    // first that failed is brought into view, the user being perhaps
    // scrolled past it.
    final invalid = _form.currentState!.validateGranularly();
    if (invalid.isNotEmpty) {
      await Scrollable.ensureVisible(
        invalid.first.context,
        duration: const Duration(milliseconds: 200),
      );
      return;
    }
    final name = _name.text.trim();
    await widget.forwards.save(
      ForwardSetting(
        id:
            widget.existing?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        hostId: _hostId!,
        name: name.isEmpty ? _defaultName : name,
        mappings: [for (final mapping in _mappings) mapping.value!],
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showTuiConfirmDialog(
      context,
      title: 'delete port forward',
      message: 'Delete this port forward?',
      detail: 'If it is on, its ports close now.',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
    );
    if (!confirmed) return;
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

    final direction = TuiSelect<_Direction>(
      options: const [
        (_Direction.tabletToRemote, 'Tablet → Remote'),
        (_Direction.remoteToTablet, 'Remote → Tablet'),
      ],
      value: mapping.direction,
      onChanged: (picked) => setState(
        () => mapping
          ..direction = picked
          ..reset(),
      ),
    );
    final portField = TuiField(
      label: mapping.tablet ? 'Tablet port' : 'Remote port',
      controller: mapping.port,
      helper: !mapping.tablet && port != null && port > 0 && port < 1024
          ? 'Hosts usually refuse ports below 1024 unless you sign in as '
                'root.'
          : null,
      keyboardType: TextInputType.number,
      validator: (_) => _portError(mapping),
      onChanged: (text) => setState(() {
        if (mapping.linked) mapping.otherPort.text = text;
      }),
    );
    final chips = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 8,
        children: [
          for (final snippet in portSnippets)
            TuiFilterChip(
              label: '${snippet.name} ${snippet.port}',
              selected: port == snippet.port,
              // Both ports take it; a host typed there stays.
              onSelected: (_) => setState(() {
                mapping
                  ..port.text = '${snippet.port}'
                  ..snippet = snippet
                  ..reset();
              }),
            ),
        ],
      ),
    );

    // termul's box.
    return Container(
      key: ObjectKey(mapping),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: TermulThemeData.of(context).palette.panel,
        border: Border.all(color: TermulThemeData.of(context).palette.border),
      ),
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
            else ...[
              direction,
              const SizedBox(height: 8),
              portField,
            ],
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
                TermulTextAction(
                  label: 'Advanced',
                  text: mapping.advanced ? 'ADVANCED ▴' : 'ADVANCED ▾',
                  onTap: () =>
                      setState(() => mapping.advanced = !mapping.advanced),
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
    Widget host(
      TextEditingController field,
      String label,
      String blank, {
      String? helper,
    }) => TuiField(
      label: label,
      controller: field,
      hint: blank,
      helper: helper,
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
          child: TuiField(
            label: mapping.tablet ? 'Remote port' : 'Tablet port',
            controller: mapping.otherPort,
            hint: 'Same',
            keyboardType: TextInputType.number,
            validator: (value) => (value ?? '').trim().isEmpty
                ? null
                : PortMapping.portError(value),
            onChanged: (_) => setState(() => mapping.linked = false),
          ),
        ),
      ],
    );

    if (mapping.tablet) {
      return [
        withPort(
          host(
            mapping.remoteHost,
            'Remote host',
            'localhost',
            helper: 'As the host reaches it: localhost is the host itself.',
          ),
        ),
      ];
    }
    final listen = mapping.listenHost.text.trim();
    final exposed = listen.isNotEmpty && !RemoteForward.loopback(listen);
    return [
      host(
        mapping.listenHost,
        'Remote listens on',
        'localhost',
        helper: exposed
            ? 'Open to the host\'s network too, and needs GatewayPorts in '
                  'its sshd_config.'
            : 'Only programs on the host itself can connect.',
      ),
      const SizedBox(height: 8),
      withPort(host(mapping.tabletHost, 'Tablet host', '127.0.0.1')),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defaultName = _defaultName;

    return Scaffold(
      appBar: TuiAppBar(
        title: Text(
          widget.existing == null ? 'New port forward' : 'Edit port forward',
        ),
        actions: [
          if (widget.existing != null) ...[
            TermulTextAction(
              label: 'Delete',
              text: 'DELETE',
              color: TermulThemeData.of(context).palette.deep,
              onTap: _delete,
            ),
            const SizedBox(width: 20),
          ],
          TermulTextAction(label: 'Save', text: 'SAVE', onTap: _save),
          const SizedBox(width: 16),
        ],
      ),
      // Not a ListView: a lazy list disposes a field scrolled far enough off,
      // and a disposed field leaves the Form, so Save never validated the
      // host or a blank port and crashed on them (JEANSH-3).
      body: Form(
        key: _form,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: pageGutters(constraints.maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                DropdownField<String>(
                  key: _hostField,
                  label: 'Host',
                  initialValue: _hostId,
                  helper:
                      'Reached as a terminal session reaches it, '
                      'through its jump host too.',
                  options: [
                    for (final host in _hosts)
                      TuiDropdownOption(
                        value: host.id,
                        label: host.displayName,
                        subtitle: host.host,
                      ),
                    const TuiDropdownOption(
                      value: _newHost,
                      label: 'New host…',
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
                TuiField(
                  label: 'Name',
                  controller: _name,
                  helper:
                      'Optional. Defaults to '
                      '${defaultName.isEmpty ? 'the host\'s name' : defaultName}.',
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 24),
                const TuiSectionLabel('Ports'),
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
                  child: TuiButton(
                    label: 'Add port',
                    prefix: '+',
                    variant: TuiButtonVariant.ghost,
                    onPressed: () => setState(() => _mappings.add(_Mapping())),
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
