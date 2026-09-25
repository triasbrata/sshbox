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
import 'tui.dart';

/// The most a key file may hold. A private key is a few KB, so a larger file
/// is something else, and is refused before it is read.
const maxKeyFileBytes = 64 * 1024;

const _keyFileTooBig =
    'That file is over 64 KB\n'
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

/// Explains why there is nothing to fill in for Tailscale SSH, in termul's
/// accent block, as its empty home explains a first connection.
class _TailscaleNotice extends StatelessWidget {
  const _TailscaleNotice();

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);
    final ink = p.isLight ? p.panel : p.bg;

    return Container(
      width: double.infinity,
      color: p.accent,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TAILSCALE SSH',
            style: theme.textTheme.labelSmall!.copyWith(
              color: ink,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Nothing is stored here: Tailscale checks who you are. The first '
            'connection may ask you to sign in through a link, and it won\'t '
            'ask again until that check expires.\n\n'
            'Use the host\'s tailnet address, and turn on Tailscale SSH there '
            'with tailscale up --ssh.',
            style: theme.textTheme.bodyMedium!.copyWith(
              color: ink,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// A password field whose eye shows or masks what was typed. Shown or not, it
/// stays out of the keyboard's suggestions and out of what it learns.
class _SecretField extends StatefulWidget {
  const _SecretField({
    required this.controller,
    required this.label,
    required this.what,
    this.helper,
    this.hint,
  });

  final TextEditingController controller;
  final String label;

  /// What it holds, as the eye's tooltip names it: "password", "passphrase".
  final String what;
  final String? helper;
  final String? hint;

  @override
  State<_SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<_SecretField> {
  var _shown = false;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return TuiField(
      label: widget.label,
      controller: widget.controller,
      hint: widget.hint,
      helper: widget.helper,
      obscure: !_shown,
      // Masked, the platform already keeps it from the keyboard; shown, only
      // these do.
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      suffix: IconButton(
        tooltip: '${_shown ? 'Hide' : 'Show'} ${widget.what}',
        color: p.dim,
        icon: Icon(_shown ? Icons.visibility_off : Icons.visibility),
        onPressed: () => setState(() => _shown = !_shown),
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
          type: TuiToastType.warning,
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
        type: TuiToastType.warning,
        duration: const Duration(seconds: 3),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      showToast(context, 'Notification key copied', type: TuiToastType.success);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    final id =
        widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString();

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
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);
    const gap = SizedBox(height: 18);
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 12),
      child: TuiSectionLabel(title),
    );

    // termul's add_connection_screen: back and what the page is along the
    // top, the page's name large, then its fields; Save as well as its word
    // at the top, so it is in reach before the form is scrolled.
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Row(
                children: [
                  TermulTextAction.back(context),
                  const Spacer(),
                  TermulTextAction(
                    label: 'Save',
                    text: 'SAVE',
                    onTap: _saving ? null : _save,
                  ),
                ],
              ),
            ),
            Expanded(
              // Not a lazy list: a field scrolled off would be let go, and
              // Save would then check only the ones on screen.
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Read out as the page's name was before termul's
                      // two lines, which the e2e flows look for.
                      Semantics(
                        header: true,
                        container: true,
                        label: _isEditing ? 'Edit host' : 'New host',
                        excludeSemantics: true,
                        child: Text(
                          _isEditing ? 'Edit\nhost' : 'Add\nhost',
                          style: theme.textTheme.displayMedium!.copyWith(
                            color: p.accent,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Address, port, username and how you sign in. The '
                        'label is optional.',
                        style: theme.textTheme.bodyMedium!.copyWith(
                          color: p.muted,
                          height: 1.5,
                        ),
                      ),
                      section('Connection'),
                      TuiField(
                        label: 'Label',
                        controller: _label,
                        hint: 'build box · staging',
                        helper: 'Optional. Blank shows user@host on Home.',
                        textInputAction: TextInputAction.next,
                      ),
                      gap,
                      TuiField(
                        label: 'Host',
                        controller: _host,
                        hint: '192.168.1.10',
                        autocorrect: false,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.next,
                        validator: (value) =>
                            (value == null || value.trim().isEmpty)
                            ? 'A hostname or IP is required'
                            : null,
                      ),
                      gap,
                      TuiField(
                        label: 'Port',
                        controller: _port,
                        hint: '22',
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
                      gap,
                      TuiField(
                        label: 'Username',
                        controller: _username,
                        hint: 'ubuntu',
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        validator: (value) =>
                            (value == null || value.trim().isEmpty)
                            ? 'A username is required'
                            : null,
                      ),
                      gap,
                      // After the three a first host needs, not between Host
                      // and Port: its help runs to three lines, which on a
                      // phone with the keyboard up pushed Port off the screen.
                      TuiField(
                        label: 'Alternative address',
                        controller: _altHost,
                        hint: '192.168.1.20',
                        helper:
                            'Optional. Another address for the same machine, '
                            'such as its LAN IP when you usually reach it over '
                            'Tailscale. Jeansh tries both and uses whichever '
                            'answers first, with the same port, user and '
                            'sign-in.',
                        autocorrect: false,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.next,
                      ),
                      if (_jumpHosts case final jumpHosts?) ...[
                        gap,
                        DropdownField<String>(
                          label: 'Jump host',
                          initialValue: _jumpHostId.isEmpty
                              ? null
                              : _jumpHostId,
                          allowClear: true,
                          emptyLabel: 'None, connect directly',
                          hint: 'None, connect directly',
                          helper: jumpHosts.isEmpty
                              ? 'To go through another host, like ssh -J, '
                                    'save that one first.'
                              : 'Optional. Connect through another saved '
                                    'host first, like ssh -J, using its own '
                                    'login. The Host field above is then the '
                                    'address as that host sees it.',
                          options: [
                            for (final host in jumpHosts)
                              TuiDropdownOption(
                                value: host.id,
                                label: host.displayName,
                                subtitle: host.host,
                              ),
                          ],
                          onChanged: (id) =>
                              setState(() => _jumpHostId = id ?? ''),
                        ),
                      ],
                      section('Session'),
                      TuiField(
                        label: 'File tree root',
                        controller: _fileRoot,
                        hint: '~/projects or /var/www',
                        helper:
                            'Optional. The folder the file tree opens in. '
                            'Blank means your home folder.',
                        autocorrect: false,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 28),
                      TuiSwitch(
                        label: 'Forward ports to the tailnet',
                        hint:
                            'A server you start in a session goes on the '
                            'tailnet by itself: vite on port 3000 shows up at '
                            'this host\'s MagicDNS name on 3001. Needs '
                            'Tailscale on a Linux host, and leave to serve '
                            'without root there (sudo tailscale set '
                            '--operator=\$USER, once).',
                        value: _forwardPorts,
                        onChanged: (value) =>
                            setState(() => _forwardPorts = value),
                      ),
                      const SizedBox(height: 28),
                      TuiSwitch(
                        label: 'Use tmux',
                        hint:
                            'Each tab runs in its own tmux session. Split it '
                            'into panes from the tab\'s '
                            '${isDesktop ? 'right-click' : 'long-press'} menu. '
                            'If the connection drops, you come back to the '
                            'same panes with their programs still running. '
                            'Closing the tab ends the session. Needs tmux on '
                            'the host.',
                        value: _useTmux,
                        onChanged: (value) => setState(() => _useTmux = value),
                      ),
                      if (_useTmux) ...[
                        const SizedBox(height: 28),
                        TuiSwitch(
                          label: 'Keep a record of each pane',
                          hint:
                              'The host writes all a pane prints to a file '
                              'under ~/.local/state/jeansh, even with the app '
                              'closed, so what clear or a full screen wiped '
                              'can be read from the tab\'s '
                              '${isDesktop ? 'right-click' : 'long-press'} '
                              'menu. Up to 16 MB a pane, the newest kept.',
                          value: _recordPanes,
                          onChanged: (value) =>
                              setState(() => _recordPanes = value),
                        ),
                      ],
                      if (_isEditing && widget.notifyKeys != null) ...[
                        const SizedBox(height: 28),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TuiButton(
                            label: 'Copy notification key',
                            prefix: '⧉',
                            variant: TuiButtonVariant.ghost,
                            onPressed: _copyNotifyKey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TuiText(
                          'Sent to this host by itself, as LC_SSHBOX_KEY. '
                          'Copy it only for a server that does not accept it.',
                          tone: TuiTextTone.dim,
                          size: 11,
                        ),
                      ],
                      section('Sign-in'),
                      TuiSelect<SshAuthMethod>(
                        options: const [
                          (SshAuthMethod.password, 'Password'),
                          (SshAuthMethod.privateKey, 'Key'),
                          (SshAuthMethod.tailscale, 'Tailscale'),
                        ],
                        value: _authMethod,
                        onChanged: (method) =>
                            setState(() => _authMethod = method),
                      ),
                      gap,
                      if (_authMethod == SshAuthMethod.tailscale)
                        const _TailscaleNotice()
                      else if (_authMethod == SshAuthMethod.password)
                        _SecretField(
                          controller: _password,
                          label: 'Password',
                          what: 'password',
                          hint: '••••••••',
                          helper: _isEditing
                              ? 'Leave blank to keep the stored password'
                              : 'Saved encrypted in the device keystore.',
                        )
                      else ...[
                        TuiField(
                          label: 'Private key (OpenSSH or PEM)',
                          controller: _privateKey,
                          maxLines: 6,
                          minLines: 3,
                          // Not obscured, so nothing else tells the keyboard
                          // to keep a private key out of its suggestions and
                          // what it learns.
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                          helper: _isEditing
                              ? 'Leave blank to keep the stored key'
                              : 'Paste the whole key, BEGIN and END lines '
                                    'included, or choose the file below.',
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TuiButton(
                            label: 'Choose file',
                            prefix: '+',
                            variant: TuiButtonVariant.ghost,
                            onPressed: _chooseKeyFile,
                          ),
                        ),
                        gap,
                        _SecretField(
                          controller: _passphrase,
                          label: 'Key passphrase',
                          what: 'passphrase',
                          helper: 'Only if the key is encrypted',
                        ),
                      ],
                      const SizedBox(height: 32),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TuiButton(
                          label: 'Save host',
                          prefix: '▸',
                          onPressed: _saving ? null : _save,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
