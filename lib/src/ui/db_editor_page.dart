import 'dart:async';

import 'package:flutter/material.dart';

import '../data/secret_store.dart';
import '../db/db_session.dart';
import '../models/forward_setting.dart' show PortMapping;
import '../models/host_profile.dart';
import 'os_icon.dart';
import 'settings_page.dart' show nerdFontFamily;
import 'tui.dart';

/// A database's own brand mark — PostgreSQL's elephant, MongoDB's leaf,
/// Redis's stack — as termul's [TuiBrand] has it: a devicon glyph of the
/// bundled Nerd Font, the same font the host OS logos are drawn from, and
/// the brand's own colour.
typedef DbBrand = ({int glyph, Color color});

/// [kind]'s brand in termul.
TuiBrand dbTuiBrand(DbKind kind) => switch (kind) {
  DbKind.postgres => TuiBrand.postgres,
  DbKind.mongo => TuiBrand.mongo,
  DbKind.redis => TuiBrand.redis,
};

/// [kind]'s brand mark, or null for a brand termul draws without one.
DbBrand? dbBrand(DbKind kind) => switch (dbTuiBrand(kind)) {
  TuiBrand(:final glyph?, :final color) => (glyph: glyph, color: color),
  _ => null,
};

/// A database's brand as termul's [TuiBrandBadge], as [OsBadge] draws a
/// host's OS, so a database and a host read as one family on Home.
class DbBadge extends StatelessWidget {
  const DbBadge(this.kind, {super.key, this.size = 36});

  final DbKind kind;

  /// The badge's side. The mark scales with it.
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: TuiBrandBadge(
      brand: dbTuiBrand(kind),
      size: size,
      reserveVersion: false,
      markFontFamily: nerdFontFamily,
    ),
  );
}

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

Future<bool> _confirmDelete(BuildContext context) => showTuiConfirmDialog(
  context,
  title: 'delete database',
  message: 'Delete this database?',
  detail: 'Its saved password goes too. Nothing changes on the server.',
  confirmLabel: 'Delete',
  cancelLabel: 'Cancel',
);

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
  late final _database = TextEditingController(text: widget.existing?.database);
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
          if (mounted && _password.text.isEmpty) {
            _password.text = password ?? '';
          }
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

  /// Fills the fields from a connection URI the user pastes. One the app
  /// cannot read says why under it, and changes nothing. A URI with no
  /// password leaves the one typed here.
  Future<void> _importUri() async {
    final uri = TextEditingController();
    String? error;
    final parsed = await showDialog<DbUri>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            try {
              Navigator.of(context).pop(parseDbUri(uri.text));
            } on FormatException catch (refused) {
              setDialogState(() => error = refused.message);
            }
          }

          return TuiDialog(
            title: 'Import URI',
            maxWidth: 420,
            actions: [
              TuiButton(
                label: 'Cancel',
                variant: TuiButtonVariant.ghost,
                onPressed: () => Navigator.of(context).pop(),
              ),
              TuiButton(label: 'Import', onPressed: submit),
            ],
            child: TuiField(
              label: 'URI',
              controller: uri,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              // It may hold a password.
              enableIMEPersonalizedLearning: false,
              keyboardType: TextInputType.url,
              hint: 'postgresql://user:password@localhost:5432/app',
              helper:
                  'A postgresql://, mongodb:// or redis:// URI fills in '
                  'this database\'s fields.',
              errorText: error,
              onSubmitted: (_) => submit(),
            ),
          );
        },
      ),
    );
    // Not disposed here: the dialog is still animating out with it.
    if (parsed == null || !mounted) return;
    setState(() {
      _kind = parsed.kind;
      _address.text = parsed.address;
      _port.text = '${parsed.port}';
      _user.text = parsed.user;
      if (parsed.password case final password?) _password.text = password;
      _database.text = parsed.database;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);
    const gap = SizedBox(height: 16);
    // As the host editor is: termul's add_connection_screen, back and the
    // page's own words along the top, the page's name large, then fields.
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
                  if (widget.existing != null) ...[
                    TermulTextAction(
                      label: 'Delete',
                      text: 'DELETE',
                      color: p.isLight ? p.deep : p.red,
                      onTap: _delete,
                    ),
                    const SizedBox(width: 20),
                  ],
                  TermulTextAction(label: 'Save', text: 'SAVE', onTap: _save),
                ],
              ),
            ),
            Expanded(
              // Not a lazy list: a field scrolled off would be let go, and
              // Save would then check only the ones on screen.
              child: Form(
                key: _form,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        header: true,
                        container: true,
                        label: widget.existing == null
                            ? 'New database'
                            : 'Edit database',
                        excludeSemantics: true,
                        child: Text(
                          widget.existing == null
                              ? 'Add\ndatabase'
                              : 'Edit\ndatabase',
                          style: theme.textTheme.displayMedium!.copyWith(
                            color: p.accent,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Reached through a saved host, as ssh -L does. The '
                        'name is optional.',
                        style: theme.textTheme.bodyMedium!.copyWith(
                          color: p.muted,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TuiButton(
                          label: 'Import URI',
                          prefix: '↓',
                          variant: TuiButtonVariant.ghost,
                          onPressed: _importUri,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const TuiSectionLabel('Database'),
                      const SizedBox(height: 10),
                      TuiSelect<DbKind>(
                        options: [
                          for (final kind in DbKind.values) (kind, kind.label),
                        ],
                        value: _kind,
                        onChanged: _pickKind,
                      ),
                      gap,
                      DropdownField<String>(
                        label: 'Host',
                        initialValue: _hostId,
                        helper: widget.hosts.isEmpty
                            ? 'Add a host first: Add, then Host, on Home.'
                            : 'Reached through its SSH connection, and its '
                                  'jump host too.',
                        options: [
                          for (final host in widget.hosts)
                            TuiDropdownOption(
                              value: host.id,
                              label: host.displayName,
                              subtitle: host.host,
                            ),
                        ],
                        validator: (value) =>
                            value == null ? 'Pick a host' : null,
                        onChanged: (id) => setState(() => _hostId = id),
                      ),
                      gap,
                      TuiField(
                        label: 'Name',
                        controller: _name,
                        helper:
                            'Optional. Defaults to ${_kind.label} on the '
                            'host\'s name.',
                      ),
                      gap,
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 12,
                        children: [
                          Expanded(
                            flex: 3,
                            child: TuiField(
                              label: 'Address',
                              controller: _address,
                              hint: 'localhost',
                              helper:
                                  'As the host reaches it: localhost is the '
                                  'host itself.',
                              autocorrect: false,
                              keyboardType: TextInputType.url,
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: TuiField(
                              label: 'Port',
                              controller: _port,
                              keyboardType: TextInputType.number,
                              validator: PortMapping.portError,
                            ),
                          ),
                        ],
                      ),
                      gap,
                      TuiField(
                        label: 'User',
                        controller: _user,
                        hint: _kind.user.isEmpty ? 'None' : _kind.user,
                        autocorrect: false,
                      ),
                      gap,
                      TuiField(
                        label: 'Password',
                        controller: _password,
                        obscure: !_showPassword,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        helper: 'Kept in the device keystore.',
                        suffix: IconButton(
                          tooltip: _showPassword
                              ? 'Hide password'
                              : 'Show password',
                          color: p.dim,
                          icon: Icon(
                            _showPassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () =>
                              setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                      gap,
                      TuiField(
                        label: switch (_kind) {
                          DbKind.postgres => 'Database',
                          DbKind.mongo => 'Authentication database',
                          DbKind.redis => 'Database number',
                        },
                        controller: _database,
                        hint: _kind.database,
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
            ),
          ],
        ),
      ),
    );
  }
}
