import 'dart:async';

import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../data/secret_store.dart';
import '../models/host_profile.dart';

class HostEditPage extends StatefulWidget {
  const HostEditPage({
    super.key,
    required this.repository,
    required this.secrets,
    this.existing,
  });

  final HostRepository repository;
  final SecretStore secrets;

  /// Null when adding a new host.
  final HostProfile? existing;

  @override
  State<HostEditPage> createState() => _HostEditPageState();
}

/// Explains why there is nothing to fill in for Tailscale SSH.
class _TailscaleNotice extends StatelessWidget {
  const _TailscaleNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'No credential is stored. Tailscale decides who you are, and '
                'the first connection may ask you to sign in through a link. '
                'After that it stops asking until the check expires.\n\n'
                'Use the host\'s tailnet address, and make sure Tailscale SSH '
                'is enabled there (tailscale up --ssh).',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HostEditPageState extends State<HostEditPage> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _label;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _fileRoot;
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();

  late SshAuthMethod _authMethod;
  late bool _forwardPorts;
  late bool _useTmux;
  late String _jumpHostId;

  /// The hosts this one can jump through: every other saved host, once read.
  List<HostProfile>? _jumpHosts;
  bool _saving = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _label = TextEditingController(text: existing?.label ?? '');
    _host = TextEditingController(text: existing?.host ?? '');
    _port = TextEditingController(text: '${existing?.port ?? 22}');
    _username = TextEditingController(text: existing?.username ?? '');
    _fileRoot = TextEditingController(text: existing?.fileRoot ?? '');
    _authMethod = existing?.authMethod ?? SshAuthMethod.password;
    _forwardPorts = existing?.forwardPorts ?? false;
    _useTmux = existing?.useTmux ?? false;
    _jumpHostId = existing?.jumpHostId ?? '';
    unawaited(_loadJumpHosts());
  }

  Future<void> _loadJumpHosts() async {
    final hosts = [
      for (final host in await widget.repository.load())
        if (host.id != widget.existing?.id) host,
    ];
    if (!mounted) return;
    setState(() {
      _jumpHosts = hosts;
      // A jump host deleted since is no jump host at all.
      if (!hosts.any((host) => host.id == _jumpHostId)) _jumpHostId = '';
    });
  }

  @override
  void dispose() {
    for (final controller in [
      _label,
      _host,
      _port,
      _username,
      _fileRoot,
      _password,
      _privateKey,
      _passphrase,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    final id = widget.existing?.id ??
        DateTime.now().microsecondsSinceEpoch.toString();

    final profile = HostProfile(
      id: id,
      label: _label.text.trim(),
      host: _host.text.trim(),
      username: _username.text.trim(),
      port: int.parse(_port.text.trim()),
      authMethod: _authMethod,
      fileRoot: _fileRoot.text.trim(),
      forwardPorts: _forwardPorts,
      useTmux: _useTmux,
      jumpHostId: _jumpHostId,
    );

    await widget.repository.upsert(profile);

    // Blank means "keep whatever is already stored", so editing a host to
    // change its port never silently wipes its credentials.
    if (_password.text.isNotEmpty) {
      await widget.secrets.write(SecretKeys.password(id), _password.text);
    }
    if (_privateKey.text.isNotEmpty) {
      await widget.secrets.write(SecretKeys.privateKey(id), _privateKey.text);
    }
    if (_passphrase.text.isNotEmpty) {
      await widget.secrets.write(SecretKeys.passphrase(id), _passphrase.text);
    }

    if (!mounted) return;
    Navigator.of(context).pop(profile);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit host' : 'New host'),
        actions: [
          IconButton(
            tooltip: 'Save',
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            TextFormField(
              controller: _label,
              decoration: const InputDecoration(
                labelText: 'Label',
                helperText: 'Optional. Defaults to user@host.',
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _host,
              decoration: const InputDecoration(labelText: 'Host'),
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'A hostname or IP is required'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _port,
              decoration: const InputDecoration(labelText: 'Port'),
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              validator: (value) {
                final port = int.tryParse(value?.trim() ?? '');
                if (port == null || port < 1 || port > 65535) {
                  return 'Port must be between 1 and 65535';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'Username'),
              autocorrect: false,
              textInputAction: TextInputAction.next,
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'A username is required'
                  : null,
            ),
            const SizedBox(height: 12),
            if (_jumpHosts case final jumpHosts?) ...[
              DropdownButtonFormField<String>(
                initialValue: _jumpHostId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Jump host',
                  helperText: jumpHosts.isEmpty
                      ? 'To connect through another host, like ssh -J, add '
                            'that host first.'
                      : 'Optional. Connects through another saved host '
                            'first, like ssh -J, signing in there with its own '
                            'login. Host above is then the address that host '
                            'reaches this one at.',
                  helperMaxLines: 3,
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('None, connect directly'),
                  ),
                  for (final host in jumpHosts)
                    DropdownMenuItem(
                      value: host.id,
                      child: Text(
                        host.displayName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (id) => setState(() => _jumpHostId = id ?? ''),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _fileRoot,
              decoration: const InputDecoration(
                labelText: 'File tree root',
                hintText: '~/projects or /var/www',
                helperText: 'Optional. Where the file tree opens after you '
                    'connect. Blank is your home directory.',
                helperMaxLines: 2,
              ),
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _forwardPorts,
              onChanged: (value) => setState(() => _forwardPorts = value),
              title: const Text('Forward ports to the tailnet'),
              subtitle: const Text(
                'A server you start in a session goes on the tailnet by '
                'itself: vite on port 3000 shows up at this host\'s MagicDNS '
                'name on 3001. Needs Tailscale on a Linux host, and leave to '
                'serve without root there (sudo tailscale set '
                '--operator=\$USER, once).',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _useTmux,
              onChanged: (value) => setState(() => _useTmux = value),
              title: const Text('Use tmux'),
              subtitle: const Text(
                'Each tab is a tmux session you can split into panes from '
                'its long-press menu. A dropped connection comes back to the '
                'same panes with their programs still running; closing the '
                'tab ends them. Needs tmux on the host.',
              ),
            ),
            const SizedBox(height: 24),
            SegmentedButton<SshAuthMethod>(
              segments: const [
                ButtonSegment(
                  value: SshAuthMethod.password,
                  label: Text('Password'),
                  icon: Icon(Icons.password),
                ),
                ButtonSegment(
                  value: SshAuthMethod.privateKey,
                  label: Text('Key'),
                  icon: Icon(Icons.vpn_key),
                ),
                ButtonSegment(
                  value: SshAuthMethod.tailscale,
                  label: Text('Tailscale'),
                  icon: Icon(Icons.shield_outlined),
                ),
              ],
              selected: {_authMethod},
              onSelectionChanged: (selection) =>
                  setState(() => _authMethod = selection.first),
            ),
            const SizedBox(height: 16),
            if (_authMethod == SshAuthMethod.tailscale)
              const _TailscaleNotice()
            else if (_authMethod == SshAuthMethod.password)
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Password',
                  helperText: _isEditing
                      ? 'Leave blank to keep the stored password'
                      : 'Stored in the device keystore, never in plain settings',
                  helperMaxLines: 2,
                ),
              )
            else ...[
              TextFormField(
                controller: _privateKey,
                maxLines: 6,
                minLines: 3,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Private key (OpenSSH or PEM)',
                  alignLabelWithHint: true,
                  helperText: _isEditing
                      ? 'Leave blank to keep the stored key'
                      : 'Paste the full key including its BEGIN/END lines',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passphrase,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Key passphrase',
                  helperText: 'Only if the key is encrypted',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
