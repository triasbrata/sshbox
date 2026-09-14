import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/db/wire.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/ui/databases_page.dart';

/// A database with one table, that answers any SQL with two rows and fails
/// on `boom`.
class _FakeSession extends DbSession {
  final ran = <String>[];
  var closed = false;

  @override
  String get hint => 'SQL';

  @override
  Future<Map<String, List<String>>> objects(String filter) async => {
    if ('users'.contains(filter)) 'public': ['users'],
  };

  @override
  Future<String> queryFor(String group, String name) async =>
      'SELECT * FROM $group.$name;';

  @override
  Future<DbResult> run(String query) async {
    ran.add(query);
    if (query.contains('boom')) throw const DbException('ERROR: boom');
    return const DbResult(
      columns: ['id', 'name'],
      rows: [
        ['1', 'ann'],
        ['2', null],
      ],
      note: 'SELECT 2',
    );
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

void main() {
  final queryBox = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.hintText == 'SQL',
  );

  // A phone in portrait, and a tablet.
  for (final width in [400.0, 1200.0]) {
    testWidgets('adds a database at $width dp, browses it, runs SQL, shows '
        'its error, and deletes it', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final secrets = InMemorySecretStore();
      final repository = HostRepository(secrets);
      await repository.upsert(
        const HostProfile(
          id: 'box',
          label: 'db box',
          host: 'db.example',
          username: 'me',
        ),
      );
      final session = _FakeSession();
      DbConnection? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: DatabasesPage(
            repository: repository,
            secrets: secrets,
            open: (db, {required confirmHostKey, required onSignIn}) async {
              opened = db;
              return session;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No databases yet'), findsOneWidget);

      // The only host is picked; Redis's port comes and goes with it.
      await tester.tap(find.byTooltip('Add database'));
      await tester.pumpAndSettle();
      final port = find.widgetWithText(TextFormField, 'Port');
      String portText() =>
          tester.widget<TextFormField>(port).controller!.text;
      expect(portText(), '5432');
      await tester.tap(find.text('Redis'));
      await tester.pumpAndSettle();
      expect(portText(), '6379');
      await tester.tap(find.text('PostgreSQL'));
      await tester.pumpAndSettle();
      expect(portText(), '5432');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        's3cret',
      );
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(find.text('PostgreSQL on db box'), findsOneWidget);
      expect(find.textContaining('localhost:5432'), findsOneWidget);
      final saved = (await loadDatabases()).single;
      expect(await secrets.read(DbConnection.passwordKey(saved.id)), 's3cret');

      await tester.tap(find.text('PostgreSQL on db box'));
      await tester.pumpAndSettle();
      expect(opened?.id, saved.id);
      if (width < 720) {
        expect(find.text('users'), findsNothing);
        await tester.tap(find.byTooltip('Tables'));
        await tester.pumpAndSettle();
      }
      expect(find.text('public'), findsOneWidget);
      await tester.tap(find.text('users'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(queryBox).controller!.text,
        'SELECT * FROM public.users;',
      );
      expect(session.ran, ['SELECT * FROM public.users;']);
      expect(find.text('SELECT 2'), findsOneWidget);
      expect(find.text('ann'), findsOneWidget);
      expect(find.text('NULL'), findsOneWidget);

      // A row whole, as column: value.
      await tester.tap(find.text('ann'));
      await tester.pumpAndSettle();
      expect(find.text('id: 1\nname: ann'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.enterText(queryBox, 'select boom');
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(find.text('ERROR: boom'), findsOneWidget);
      expect(find.text('ann'), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(session.closed, isTrue);

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Password'),
            )
            .controller!
            .text,
        's3cret',
      );
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('No databases yet'), findsOneWidget);
      expect(await loadDatabases(), isEmpty);
      expect(await secrets.read(DbConnection.passwordKey(saved.id)), isNull);
    });
  }
}
