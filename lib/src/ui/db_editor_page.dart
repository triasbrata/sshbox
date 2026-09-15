import 'dart:async';

import 'package:flutter/material.dart';

import '../data/secret_store.dart';
import '../db/db_session.dart';
import '../models/forward_setting.dart' show PortMapping;
import '../models/host_profile.dart';
import 'os_icon.dart';
import 'port_forwarding_page.dart' show pageGutters;

IconData dbIcon(DbKind kind) => switch (kind) {
  DbKind.postgres => Icons.table_chart_outlined,
  DbKind.mongo => Icons.data_object,
  DbKind.redis => Icons.bolt,
};

/// What the editor closes with: the database saved, or the one deleted.
typedef _Edit = ({DbConnection db, bool deleted});

/// The database editor, for a new database or [existing]. What it closes
/// with is saved: the database and its password, or its deletion. True when
/// anything changed.
Future<bool> editDatabase(
  BuildContext context, {
  required List<HostProfile> hosts,
  required SecretStore secrets,
  DbConnection? existing,
}) async {
  final edit = await Navigator.of(context).push<_Edit>(
    MaterialPageRoute(
      builder: (_) =>
          _DbEditor(hosts: hosts, secrets: secrets, existing: existing),
    ),
  );
  if (edit == null) return false;
  if (edit.deleted) {
    await _forget(edit.db, secrets);
    return true;
  }
  final databases = await loadDatabases();
  final at = databases.indexWhere((db) => db.id == edit.db.id);
  if (at < 0) {
    databases.add(edit.db);
  } else {
    databases[at] = edit.db;
  }
  await saveDatabases(databases);
  return true;
}

/// Asks first, then deletes [db] and its saved password. True once deleted.
Future<bool> deleteDatabase(
  BuildContext context,
  DbConnection db,
  SecretStore secrets,
) async {
  if (!await _confirmDelete(context)) return false;
  await _forget(db, secrets);
  return true;
}

Future<void> _forget(DbConnection db, SecretStore secrets) async {
  await saveDatabases([
    for (final saved in await loadDatabases())
      if (saved.id != db.id) saved,
  ]);
  await secrets.write(DbConnection.passwordKey(db.id), null);
}

Future<bool> _confirmDelete(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this database?'),
        content: const Text(
          'Its saved password goes too. Nothing changes on the server.',
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
    ) ==
    true;

class _DbEditor extends StatefulWidget {
  const _DbEditor({required this.hosts, required this.secrets, this.existing});

  final List<HostProfile> hosts;
  final SecretStore secrets;

  /// Null when adding one.
  final DbConnection? existing;

  @override
  State<_DbEditor> createState() => _DbEditorState();
}

class _DbEditorState extends State<_DbEditor> {
  final _form = GlobalKey<FormState>();
  late var _kind = widget.existing?.kind ?? DbKind.postgres;

  /// A host deleted since is no host at all; the only one is picked.
  late String? _hostId =
      widget.hosts
          .where((host) => host.id == widget.existing?.hostId)
          .firstOrNull
          ?.id ??
      (widget.hosts.length == 1 ? widget.hosts.single.id : null);
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _address = TextEditingController(
    text: widget.existing?.address ?? 'localhost',
  );
  late final _port = TextEditingController(
    text: '${widget.existing?.port ?? _kind.port}',
  );
  late final _user = TextEditingController(text: widget.existing?.user);
  final _password = TextEditingController();
  late final _database = TextEditingController(
    text: widget.existing?.database,
  );
  var _showPassword = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      unawaited(
        widget.secrets.read(DbConnection.passwordKey(existing.id)).then((
          password,
        ) {
          if (mounted && _password.text.isEmpty) _password.text = password ?? '';
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final field in [_name, _address, _port, _user, _password, _database]) {
      field.dispose();
    }
    super.dispose();
  }

  /// A port still on the last kind's default takes the new one's.
  void _pickKind(DbKind kind) => setState(() {
    final port = _port.text.trim();
    if (port.isEmpty || port == '${_kind.port}') _port.text = '${kind.port}';
    _kind = kind;
  });

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final address = _address.text.trim();
    final db = DbConnection(
      id:
          widget.existing?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      kind: _kind,
      hostId: _hostId!,
      name: _name.text.trim(),
      address: address.isEmpty ? 'localhost' : address,
      port: int.parse(_port.text.trim()),
      user: _user.text.trim(),
      database: _database.text.trim(),
    );
    await widget.secrets.write(DbConnection.passwordKey(db.id), _password.text);
    if (mounted) Navigator.of(context).pop<_Edit>((db: db, deleted: false));
  }

  Future<void> _delete() async {
    if (!await _confirmDelete(context) || !mounted) return;
    Navigator.of(context).pop<_Edit>((db: widget.existing!, deleted: true));
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration hinted(String label, String hint, {String? helper}) =>
        InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 3,
          floatingLabelBehavior: FloatingLabelBehavior.always,
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existing == null ? 'New database' : 'Edit database',
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
            padding: pageGutters(constraints.maxWidth),
            children: [
              const SizedBox(height: 8),
              SegmentedButton<DbKind>(
                showSelectedIcon: false,
                segments: [
                  for (final kind in DbKind.values)
                    ButtonSegment(value: kind, label: Text(kind.label)),
                ],
                selected: {_kind},
                onSelectionChanged: (picked) => _pickKind(picked.single),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _hostId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Host',
                  helperText: widget.hosts.isEmpty
                      ? 'Add a host first: Add, then Host, on Home.'
                      : 'Reached through its SSH connection, and its jump '
                            'host too.',
                  helperMaxLines: 2,
                ),
                items: [
                  for (final host in widget.hosts)
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
                ],
                validator: (value) => value == null ? 'Pick a host' : null,
                onChanged: (id) => setState(() => _hostId = id),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: 'Name',
                  helperText:
                      'Optional. Defaults to ${_kind.label} on the host\'s '
                      'name.',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _address,
                      decoration: hinted(
                        'Address',
                        'localhost',
                        helper:
                            'As the host reaches it: localhost is the host '
                            'itself.',
                      ),
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _port,
                      decoration: const InputDecoration(labelText: 'Port'),
                      keyboardType: TextInputType.number,
                      validator: PortMapping.portError,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _user,
                decoration: hinted(
                  'User',
                  _kind.user.isEmpty ? 'None' : _kind.user,
                ),
                autocorrect: false,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                  labelText: 'Password',
                  helperText: 'Kept in the device keystore.',
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                    icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _database,
                decoration: hinted(switch (_kind) {
                  DbKind.postgres => 'Database',
                  DbKind.mongo => 'Authentication database',
                  DbKind.redis => 'Database number',
                }, _kind.database),
                autocorrect: false,
                keyboardType: _kind == DbKind.redis
                    ? TextInputType.number
                    : TextInputType.text,
                validator: (value) =>
                    _kind == DbKind.redis &&
                        (value ?? '').trim().isNotEmpty &&
                        int.tryParse(value!.trim()) == null
                    ? 'A number, like 0'
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
