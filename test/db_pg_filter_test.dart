import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/db/wire.dart';
import 'package:sshbox/src/ui/db_browser_page.dart';
import 'package:sshbox/src/ui/toast.dart';
import 'package:sshbox/src/ui/tui.dart';

/// A database that keeps every query run and answers with one row of a
/// table, editable or not as [edit] says.
class _Fake extends DbSession {
  _Fake({this.edit});

  final DbEdit? edit;
  final runs = <String>[];

  @override
  String get hint => 'SQL, like SELECT * FROM users LIMIT 10;';

  @override
  Future<Map<String, List<DbObject>>> objects(
    String filter, {
    String? type,
  }) async => {
    'public': [(name: 'people', type: 'BASE TABLE')],
  };

  @override
  Future<String> queryFor(String group, String name) async =>
      postgresFilterQuery(schema: group, table: name);

  @override
  Future<DbResult> run(String query) async {
    runs.add(query);
    return DbResult(
      columns: const ['id', 'name'],
      rows: const [
        ['1', 'ann'],
      ],
      note: 'SELECT 1',
      edit: edit,
    );
  }
}

Future<_Fake> _open(
  WidgetTester tester, {
  DbKind kind = DbKind.postgres,
  _Fake? db,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = db ?? _Fake();
  await tester.pumpWidget(
    MaterialApp(
        builder: (context, child) => ToastLayer(child: child!),
        home: DbBrowserPage(
          db: DbConnection(id: 'db', kind: kind, hostId: 'box', port: 5432),
          title: 'A database on box',
          open: (_, {required confirmHostKey, required onSignIn}) async =>
              session,
        ),
      ),
  );
  await tester.pumpAndSettle();
  return session;
}

/// One condition, ticked on.
PgFilter _on(String column, PgOp op, [String value = '']) =>
    (on: true, column: column, op: op, value: value);

void main() {
  group('the SQL a filter builds', () {
    test('no conditions is the table whole, as a tap on it always was', () {
      expect(
        postgresFilterQuery(schema: 'public', table: 'Jeansh People'),
        'SELECT * FROM public."Jeansh People" LIMIT 100;',
      );
    });

    test('every operator', () {
      String one(PgOp op, [String value = 'x']) => postgresFilterQuery(
        schema: 'public',
        table: 'people',
        filters: [_on('name', op, value)],
      );
      expect(one(PgOp.eq), contains("WHERE name = E'x'"));
      expect(one(PgOp.ne), contains("WHERE name <> E'x'"));
      expect(one(PgOp.gt), contains("WHERE name > E'x'"));
      expect(one(PgOp.lt), contains("WHERE name < E'x'"));
      expect(one(PgOp.ge), contains("WHERE name >= E'x'"));
      expect(one(PgOp.le), contains("WHERE name <= E'x'"));
      expect(
        one(PgOp.contains),
        contains("WHERE name::text LIKE E'%x%' ESCAPE E'\\\\'"),
      );
      expect(one(PgOp.startsWith), contains("LIKE E'x%'"));
      expect(one(PgOp.endsWith), contains("LIKE E'%x'"));
      expect(one(PgOp.isNull), contains('WHERE name IS NULL LIMIT'));
      expect(one(PgOp.isNotNull), contains('WHERE name IS NOT NULL LIMIT'));
      expect(one(PgOp.inList, 'a, b'), contains("WHERE name IN (E'a', E'b')"));
    });

    test('a row left out by its tick asks nothing', () {
      expect(
        postgresFilterQuery(
          schema: 'public',
          table: 'people',
          filters: [
            (on: false, column: 'name', op: PgOp.eq, value: 'ann'),
            _on('id', PgOp.gt, '3'),
          ],
        ),
        "SELECT * FROM public.people WHERE id > E'3' LIMIT 100;",
      );
      // Every row off is the table whole, not an empty WHERE.
      expect(
        postgresFilterQuery(
          table: 'people',
          filters: [(on: false, column: 'name', op: PgOp.eq, value: 'ann')],
        ),
        'SELECT * FROM people LIMIT 100;',
      );
    });

    test('AND joins them, and OR when asked', () {
      final filters = [_on('name', PgOp.eq, 'ann'), _on('id', PgOp.gt, '3')];
      expect(
        postgresFilterQuery(table: 'people', filters: filters),
        "SELECT * FROM people WHERE name = E'ann' AND id > E'3' LIMIT 100;",
      );
      expect(
        postgresFilterQuery(table: 'people', filters: filters, any: true),
        "SELECT * FROM people WHERE name = E'ann' OR id > E'3' LIMIT 100;",
      );
    });

    test('a quote, a backslash and a newline reach the server as they are', () {
      expect(
        postgresFilterQuery(
          table: 'people',
          filters: [_on('name', PgOp.eq, "it's a \\ one\nmore")],
        ),
        "SELECT * FROM people WHERE name = E'it''s a \\\\ one\nmore' "
        'LIMIT 100;',
      );
      // An identifier is quoted the way the grid's own saves quote it.
      expect(
        postgresFilterQuery(
          table: 'people',
          filters: [_on('The "Name"', PgOp.eq, 'ann')],
        ),
        contains('WHERE "The ""Name""" ='),
      );
    });

    test("LIKE's own % and _ are the value's, not a wildcard", () {
      expect(
        postgresFilterQuery(
          table: 'people',
          filters: [_on('name', PgOp.contains, r'50%_off\x')],
        ),
        contains(r"LIKE E'%50\\%\\_off\\\\x%' ESCAPE E'\\'"),
      );
    });

    test('in takes a list, each item quoted on its own', () {
      expect(
        postgresFilterQuery(
          table: 'people',
          filters: [_on('name', PgOp.inList, " ann , it's , bob ")],
        ),
        "SELECT * FROM people WHERE name IN (E'ann', E'it''s', E'bob') "
        'LIMIT 100;',
      );
    });

    test('a NUL is refused rather than cutting the query short', () {
      expect(
        () => postgresFilterQuery(
          table: 'people',
          filters: [_on('name', PgOp.eq, 'ann\u0000; DROP TABLE people')],
        ),
        throwsA(
          isA<DbException>().having((e) => '$e', 'says', contains('NUL')),
        ),
      );
    });

    test('a row not filled in says which, before anything is sent', () {
      expect(
        () => postgresFilterQuery(
          table: 'people',
          filters: [_on('id', PgOp.gt, '3'), _on('name', PgOp.eq)],
        ),
        throwsA(
          isA<DbException>().having(
            (e) => '$e',
            'says',
            allOf(contains('Condition 2'), contains('=')),
          ),
        ),
      );
      expect(
        () => postgresFilterQuery(
          table: 'people',
          filters: [_on('', PgOp.eq, 'ann')],
        ),
        throwsA(
          isA<DbException>().having(
            (e) => '$e',
            'says',
            contains('Condition 1 has no column'),
          ),
        ),
      );
      // A row with nothing in it asks nothing: the tab always holds one.
      expect(
        postgresFilterQuery(table: 'people', filters: [_on('', PgOp.eq)]),
        'SELECT * FROM people LIMIT 100;',
      );
      // is null wants none, so an empty value is not missing.
      expect(
        postgresFilterQuery(
          table: 'people',
          filters: [_on('name', PgOp.isNull)],
        ),
        'SELECT * FROM people WHERE name IS NULL LIMIT 100;',
      );
    });

    test('with no table picked it says to pick one', () {
      expect(
        () => postgresFilterQuery(table: ''),
        throwsA(
          isA<DbException>().having(
            (e) => '$e',
            'says',
            contains('Tap a table'),
          ),
        ),
      );
    });
  });

  testWidgets('PostgreSQL is asked by tab, and Redis is not', (tester) async {
    await _open(tester);
    expect(find.text('Filters'), findsOneWidget);
    expect(find.text('SQL'), findsOneWidget);

    await _open(tester, kind: DbKind.redis);
    expect(find.text('Filters'), findsNothing);
    expect(find.text('SQL'), findsNothing);
  });

  testWidgets('a table tapped fills Filters and runs it', (tester) async {
    final db = await _open(tester);
    expect(find.text('Tap a table in the list to filter it'), findsOneWidget);

    await tester.tap(find.text('people'));
    await tester.pumpAndSettle();
    expect(find.text('public.people'), findsOneWidget);
    expect(db.runs.single, 'SELECT * FROM public.people LIMIT 100;');

    // The columns on offer are the ones that run came back with.
    await tester.tap(find.byType(TuiDropdown<String>));
    await tester.pumpAndSettle();
    expect(find.text('id'), findsWidgets);
    expect(find.text('name'), findsWidgets);
    await tester.tap(find.text('name').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TuiDropdown<PgOp>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('contains').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Value 1'), 'an');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(
      db.runs.last,
      "SELECT * FROM public.people WHERE name::text LIKE E'%an%' "
      "ESCAPE E'\\\\' LIMIT 100;",
    );
  });

  testWidgets('a second condition brings AND or OR, and Clear empties them', (
    tester,
  ) async {
    final db = await _open(tester);
    await tester.tap(find.text('people'));
    await tester.pumpAndSettle();
    expect(find.text('OR'), findsNothing);

    await tester.tap(find.byType(TuiDropdown<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('name').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Value 1'), 'ann');

    await tester.tap(find.text('Add condition'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TuiDropdown<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('id').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Value 2'), '3');
    await tester.tap(find.text('OR'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(
      db.runs.last,
      "SELECT * FROM public.people WHERE name = E'ann' OR id = E'3' "
      'LIMIT 100;',
    );

    // Its tick leaves a row out without deleting it.
    await tester.tap(find.byType(TuiCheckbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(
      db.runs.last,
      "SELECT * FROM public.people WHERE id = E'3' LIMIT 100;",
    );

    await tester.tap(find.bySemanticsLabel('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(db.runs.last, 'SELECT * FROM public.people LIMIT 100;');
  });

  testWidgets('a row not filled in is said, and nothing is sent', (
    tester,
  ) async {
    final db = await _open(tester);
    await tester.tap(find.text('people'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TuiDropdown<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('name').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Condition 1'), findsOneWidget);
    expect(db.runs, hasLength(1));
  });

  testWidgets('the SQL tab keeps the free-text box, and its query', (
    tester,
  ) async {
    final db = await _open(tester);
    await tester.tap(find.text('people'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('SQL'));
    await tester.pumpAndSettle();
    expect(find.text('SELECT * FROM public.people LIMIT 100;'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'SELECT 1');
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(db.runs.last, 'SELECT 1');
  });

  testWidgets('changes not saved are asked about before another tab shows', (
    tester,
  ) async {
    final db = await _open(tester, db: _Fake(edit: DbEdit((_) async => null)));
    await tester.tap(find.text('people'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ann'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'bob');
    await tester.tap(find.bySemanticsLabel('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('SQL'));
    await tester.pumpAndSettle();
    expect(find.text('Discard 1 change?'), findsOneWidget);

    // Kept: the tab does not change behind the question.
    await tester.tap(find.bySemanticsLabel('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Add condition'), findsOneWidget);
    expect(db.runs, hasLength(1));
  });
}
