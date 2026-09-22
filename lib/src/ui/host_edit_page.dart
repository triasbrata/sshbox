import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/host_repository.dart';
import '../data/secret_store.dart';
import '../models/host_profile.dart';
import '../notifications/notify_key.dart';
import '../platform.dart';
import 'toast.dart';

/// The most a key file may hold. A private key is a few KB, so a larger file
/// is something else, and is refused before it is read.
const maxKeyFileBytes = 64 * 1024;

const _keyFileTooBig = 'That file is over 64 KB\n'
    'A private key is a few KB. Pick the key file itself.';

/// A private key from BEGIN to its own END: OpenSSH's format, PKCS#1 RSA
/// (encrypted or not), SEC1 EC, DSA, and PKCS#8 plain or encrypted.
final _privateKeyBlock = RegExp(
  r'-----BEGIN ((?:OPENSSH |RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY)-----'
  r'[\s\S]+-----END \1-----',
);

/// A public key: an authorized_keys line (`ssh-ed25519 AAAA…`), or a PEM or
/// RFC 4716 block.
final _publicKey = RegExp(
  r'^(?:ssh-|ecdsa-|sk-)\S+ AAAA|PUBLIC KEY-----',
  multiLine: true,
);

/// The text of the private key in a key file's [bytes], to be stored as is,
/// the way a pasted key is. Throws a [FormatException] whose message tells
/// the user why the file is not one: a heading, then what to do.
String privateKeyFromFile(List<int> bytes) {
  if (bytes.length > maxKeyFileBytes) {
    throw const FormatException(_keyFileTooBig);
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  if (text.contains('\uFFFD') || text.contains('\x00')) {
    throw const FormatException(
      "That file isn't text\n"
      'A private key file is text, with a BEGIN … PRIVATE KEY line.',
    );
  }
  if (_privateKeyBlock.hasMatch(text)) return text;
  // dartssh2 reads no PuTTY keys.
  if (text.trimLeft().startsWith('PuTTY-User-Key-File-')) {
    throw const FormatException(
      "That's a PuTTY key (.ppk)\n"
      'Convert it to OpenSSH format first: '
      'puttygen key.ppk -O private-openssh -o key',
    );
  }
  if (_publicKey.hasMatch(text)) {
    throw const FormatException(
      "That's the public half of the key\n"
      'Pick the private file: the one without .pub, like id_ed25519.',
    );
  }
  throw const FormatException(
    "That file isn't a private key\n"
    'Pick an OpenSSH or PEM private key, the file with a BEGIN … PRIVATE '
    'KEY line.',
  );
}

class HostEditPage extends StatefulWidget {
  const HostEditPage({
    super.key,
    required this.repository,
    required this.secrets,
    this.existing,
    this.notifyKeys,
  });

  final HostRepository repository;
  final SecretStore secrets;

  /// Null when adding a new host.
  final HostProfile? existing;

  /// Where a saved host's notification key is copied from. Left out, the
  /// page offers none.
  final NotifyKeys? notifyKeys;

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

/// A password field whose eye shows or masks what was typed. Shown or not, it
/// stays out of the keyboard's suggestions and out of what it learns.
class _SecretField extends StatefulWidget {
  const _SecretField({
    required this.controller,
    required this.what,
    required this.decoration,
  });

  final TextEditingController controller;

  /// What it holds, as the eye's tooltip names it: "password", "passphrase".
  final String what;

  final InputDecoration decoration;

  @override
  State<_SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<_SecretField> {
  var _shown = false;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      obscureText: !_shown,
      // Masked, the platform already keeps it from the keyboard; shown, only
      // these do.
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      decoration: widget.decoration.copyWith(
        suffixIcon: IconButton(
          tooltip: '${_shown ? 'Hide' : 'Show'} ${widget.what}',
          icon: Icon(_shown ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _shown = !_shown),
        ),
      ),
    );
  }
}

class _HostEditPageState extends State<HostEditPage> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _label;
  late final TextEditingController _host;
  late final TextEditingController _altHost;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _fileRoot;
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();

  late SshAuthMethod _authMethod;
  late bool _forwardPorts;
  late bool _useTmux;
  late bool _recordPanes;
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
    _altHost = TextEditingController(text: existing?.altHost ?? '');
    _port = TextEditingController(text: '${existing?.port ?? 22}');
    _username = TextEditingController(text: existing?.username ?? '');
    _fileRoot = TextEditingController(text: existing?.fileRoot ?? '');
    _authMethod = existing?.authMethod ?? SshAuthMethod.password;
    _forwardPorts = existing?.forwardPorts ?? false;
    _useTmux = existing?.useTmux ?? false;
    _recordPanes = existing?.recordPanes ?? true;
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
      _altHost,
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

  /// Reads the private key in a file the user picks into the key field, where
  /// it is saved as a pasted key is, or says why the file isn't one.
  Future<void> _chooseKeyFile() async {
    // Any type: key files seldom have an extension.
    final file = await FilePicker.pickFile();
    if (file == null) return;

    final String key;
    try {
      // Sized before it is read, so no large file lands in memory.
      if (await file.length() > maxKeyFileBytes) {
        throw const FormatException(_keyFileTooBig);
      }
      key = privateKeyFromFile(await file.readAsBytes());
    } on Exception catch (error) {
      if (mounted) {
        showToast(
          context,
          error is FormatException ? error.message : "Couldn't read that file",
          type: ToastificationType.warning,
          duration: const Duration(seconds: 6),
        );
      }
      return;
    } finally {
      // Android's picker hands over a copy in the app's cache
      // (cache/file_picker/), and a private key must not stay there in plain
      // text: this deletes every copy it made. Not a delete of file.path,
      // which on a desktop is the user's own key file.
      await FilePicker.clearTemporaryFiles();
    }
    if (mounted) _privateKey.text = key;
  }

  /// This host's `LC_SSHBOX_KEY`, for a server whose sshd will not take it
  /// with the connection.
  Future<void> _copyNotifyKey() async {
    final value = await widget.notifyKeys!.valueFor(widget.existing!.id);
    if (!mounted) return;
    if (value == null) {
      showToast(
        context,
        'No notification key yet\nThis host gets one when it next connects.',
        type: ToastificationType.warning,
        duration: const Duration(seconds: 3),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      showToast(
        context,
        'Notification key copied',
        type: ToastificationType.success,
      );
    }
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
      altHost: _altHost.text.trim(),
      username: _username.text.trim(),
      port: int.parse(_port.text.trim()),
      authMethod: _authMethod,
      fileRoot: _fileRoot.text.trim(),
      forwardPorts: _forwardPorts,
      useTmux: _useTmux,
      recordPanes: _recordPanes,
      jumpHostId: _jumpHostId,
      // Not the form's: the host says it again on its next connect.
      os: widget.existing?.os,
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
              controller: _altHost,
              decoration: const InputDecoration(
                labelText: 'Alternative address',
                hintText: '192.168.1.20',
                helperText: 'Optional. A second address for the same machine, '
                    'dialled alongside the one above and used if it answers '
                    'first: the LAN address of a host you normally reach over '
                    'Tailscale, so a tailnet that is down needs no edit here. '
                    'Same port, user and credentials.',
                helperMaxLines: 5,
              ),
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
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
              subtitle: Text(
                'Each tab is a tmux session you can split into panes from '
                'its ${isDesktop ? 'right-click' : 'long-press'} menu. A '
                'dropped connection comes back to the same panes with their '
                'programs still running; closing the tab ends them. Needs '
                'tmux on the host.',
              ),
            ),
            if (_useTmux)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _recordPanes,
                onChanged: (value) => setState(() => _recordPanes = value),
                title: const Text('Keep a record of each pane'),
                subtitle: Text(
                  'The host writes all a pane prints to a file under '
                  '~/.local/state/jeansh, even with the app closed, so what '
                  'clear or a full screen wiped can be read from the tab\'s '
                  '${isDesktop ? 'right-click' : 'long-press'} menu. Up to '
                  '16 MB a pane, the newest kept.',
                ),
              ),
            if (_isEditing && widget.notifyKeys != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.key_outlined),
                title: const Text('Copy notification key'),
                subtitle: const Text(
                  'Sent to this host by itself, as LC_SSHBOX_KEY. Copy it '
                  'only for a server that does not accept it.',
                ),
                onTap: _copyNotifyKey,
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
              _SecretField(
                controller: _password,
                what: 'password',
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
                // Not obscured, so nothing else tells the keyboard to keep a
                // private key out of its suggestions and what it learns.
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                  labelText: 'Private key (OpenSSH or PEM)',
                  alignLabelWithHint: true,
                  helperText: _isEditing
                      ? 'Leave blank to keep the stored key'
                      : 'Paste the full key including its BEGIN/END lines',
                  helperMaxLines: 2,
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: _chooseKeyFile,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Choose file'),
                ),
              ),
              const SizedBox(height: 12),
              _SecretField(
                controller: _passphrase,
                what: 'passphrase',
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
