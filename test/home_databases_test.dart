import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/ui/tui.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/db/wire.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/ui/hosts_page.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';

import 'tui_finders.dart';

/// A database with one table, that answers any SQL with two rows and fails
/// on `boom`.
class _FakeSession extends DbSession {
  var closed = false;

  @override
  String get hint => 'SQL';

  @override
  Future<Map<String, List<DbObject>>> objects(
    String filter, {
    String? type,
  }) async => {
    if ('users'.contains(filter))
      'public': [(name: 'users', type: 'BASE TABLE')],
  };

  @override
  Future<String> queryFor(String group, String name) async =>
      'SELECT * FROM $group.$name;';

  @override
  Future<DbResult> run(String query) async {
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
  test('a database opened twice has one tab, and closing the one showing '
      'lands on its left-hand neighbour, then on the host list', () {
    final sessions = SessionManager();
    const a = DbConnection(
      id: 'a',
      kind: DbKind.redis,
      hostId: 'box',
      port: 6379,
    );
    const b = DbConnection(
      id: 'b',
      kind: DbKind.mongo,
      hostId: 'box',
      port: 27017,
    );
    sessions
      ..openDb(a, 'A')
      ..openDb(b, 'B')
      ..openDb(a, 'A again');
    expect([for (final tab in sessions.dbTabs) tab.title], ['A', 'B']);
    expect(sessions.activeDb?.title, 'A');

    sessions
      ..select(null, db: sessions.dbTabs.last)
      ..closeDb(sessions.dbTabs.last);
    expect(sessions.activeDb?.title, 'A');
    sessions.closeDb(sessions.dbTabs.single);
    expect(sessions.activeDb, isNull);
    expect(sessions.activeId, isNull);
  });

  final queryBox = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.hintText == 'SQL',
  );
  // On Home, not the tab chip that shares its name.
  final card = find.descendant(
    of: find.byType(HomeRow),
    matching: find.text('PostgreSQL on db box'),
  );
  final closeTab = find.byTooltip('Close PostgreSQL on db box');

  // A phone in portrait, and a tablet.
  for (final width in [400.0, 1200.0]) {
    testWidgets('at $width dp: Add offers Host and Database above it, a '
        'saved database is on Home and opens in a tab, and is deleted from '
        'its card', (tester) async {
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
      final sessions = SessionManager();
      final session = _FakeSession();
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TabsShell(
            repository: repository,
            secrets: secrets,
            sessions: sessions,
            onOpenHost: (_) async {},
            openDatabase:
                (db, {required confirmHostKey, required onSignIn}) async {
                  opens++;
                  return session;
                },
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Hosts alone read as they always have: no headings.
      expect(find.text('db box'), findsOneWidget);
      expect(find.text('HOSTS'), findsNothing);

      // Add stacks Database over Host over itself; a tap elsewhere puts
      // them away.
      expect(findTuiButton('Host'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Add'));
      await tester.pumpAndSettle();
      Rect fab(String label) => tester.getRect(findTuiButton(label));
      expect(fab('Host').bottom, lessThanOrEqualTo(fab('Add').top));
      expect(fab('Database').bottom, lessThanOrEqualTo(fab('Host').top));
      await tester.tap(find.bySemanticsLabel('Jeansh'));
      await tester.pumpAndSettle();
      expect(findTuiButton('Host'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Add'));
      await tester.pumpAndSettle();
      await tester.tap(findTuiButton('Database'));
      await tester.pumpAndSettle();
      // Filled from a URI, its password too. One the app cannot read says
      // why, and stays open.
      await tester.tap(find.bySemanticsLabel('Import URI'));
      await tester.pumpAndSettle();
      final uriField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText?.startsWith('postgresql://') == true,
      );
      await tester.enterText(uriField, 'mysql://db.example/shop');
      await tester.tap(find.bySemanticsLabel('Import'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Not a database URI'), findsOneWidget);
      await tester.enterText(
        uriField,
        'postgresql://ann:s3cret@localhost:5432/shop',
      );
      await tester.tap(find.bySemanticsLabel('Import'));
      await tester.pumpAndSettle();
      expect(uriField, findsNothing);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Hosts'), findsOneWidget);
      expect(find.text('DATABASES'), findsOneWidget);
      expect(card, findsOneWidget);
      expect(find.text('PostgreSQL · ann@localhost:5432/shop'), findsOneWidget);
      final saved = (await loadDatabases()).single;
      expect(await secrets.read(DbConnection.passwordKey(saved.id)), 's3cret');

      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(closeTab, findsOneWidget);
      expect(sessions.activeDb?.db.id, saved.id);
      if (width < 720) {
        await tester.tap(find.byTooltip('Tables'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('users'));
      await tester.pumpAndSettle();
      // PostgreSQL opens on Filters; the SQL tab holds what the tap filled
      // in.
      await tester.tap(find.text('SQL'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(queryBox).controller!.text,
        'SELECT * FROM public.users;',
      );
      expect(find.text('ann'), findsOneWidget);

      // The same rows as JSON, a card each, and back to the grid.
      await tester.tap(find.byTooltip('JSON'));
      await tester.pumpAndSettle();
      expect(find.textContaining('name: "ann"'), findsOneWidget);
      expect(find.textContaining('name: null'), findsOneWidget);
      expect(find.byTooltip('Copy JSON'), findsNWidgets(2));
      expect(find.text('ann'), findsNothing);
      await tester.tap(find.byTooltip('Table'));
      await tester.pumpAndSettle();
      expect(find.text('ann'), findsOneWidget);

      await tester.enterText(queryBox, 'select boom');
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(find.text('ERROR: boom'), findsOneWidget);

      // Home and back: the same tab, on the same connection, as it was left.
      await tester.tap(find.byTooltip('Home'));
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(closeTab, findsOneWidget);
      expect(opens, 1);
      expect(find.text('ERROR: boom'), findsOneWidget);

      // Its close button lets the connection go, and lands on Home.
      await tester.tap(closeTab);
      await tester.pumpAndSettle();
      expect(session.closed, isTrue);
      expect(closeTab, findsNothing);
      expect(card, findsOneWidget);

      await tester.tap(find.byType(TuiMenuButton<VoidCallback>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('DATABASES'), findsNothing);
      expect(await loadDatabases(), isEmpty);
      expect(await secrets.read(DbConnection.passwordKey(saved.id)), isNull);
    });
  }
}
