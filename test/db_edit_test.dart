import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/ui/db_browser_page.dart';

/// A PostgreSQL table of two people that keeps every run, and always reads
/// the same rows back.
class _People extends DbSession {
  final runs = <String>[];

  @override
  String get hint => 'SQL';

  @override
  Future<Map<String, List<String>>> objects(String filter) async => {};

  @override
  Future<String> queryFor(String group, String name) async => '';

  @override
  Future<DbResult> run(String query) async {
    runs.add(query);
    return const DbResult(
      columns: ['id', 'name'],
      rows: [
        ['1', 'ann'],
        ['2', null],
      ],
      note: 'SELECT 2',
      table: DbTable(
        name: 'public.people',
        columns: ['id', '"Name"'],
        key: [0],
      ),
    );
  }
}

const _hint = 'Tap a cell to edit it, hold a row to delete it';

Future<_People> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final people = _People();
  await tester.pumpWidget(
    MaterialApp(
      home: DbBrowserPage(
        db: const DbConnection(
          id: 'pg',
          kind: DbKind.postgres,
          hostId: 'box',
          port: 5432,
        ),
        title: 'PostgreSQL on box',
        open: (db, {required confirmHostKey, required onSignIn}) async =>
            people,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.hintText == 'SQL',
    ),
    'SELECT * FROM people',
  );
  await tester.tap(find.text('Run'));
  await tester.pumpAndSettle();
  return people;
}

/// Taps [cell] and types [text] as its value.
Future<void> _type(WidgetTester tester, Finder cell, String text) async {
  await tester.tap(cell);
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    text,
  );
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cells edited, rows deleted and added, all saved at once', (
    tester,
  ) async {
    final people = await _open(tester);
    expect(find.text(_hint), findsOneWidget);

    await _type(tester, find.text('ann'), r"O'Brien\");
    expect(find.text(r"O'Brien\"), findsOneWidget);
    expect(find.text('1 change not saved'), findsOneWidget);

    await tester.longPress(find.text('2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete row'));
    await tester.pumpAndSettle();

    // A new row goes on top, every cell its default until given a value.
    await tester.tap(find.byTooltip('Add row'));
    await tester.pumpAndSettle();
    expect(find.text('DEFAULT'), findsNWidgets(2));
    await _type(tester, find.text('DEFAULT').last, 'bob');
    expect(find.text('3 changes not saved'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(people.runs, [
      'SELECT * FROM people',
      [
        r"DELETE FROM public.people WHERE id = E'2';",
        r'''UPDATE public.people SET "Name" = E'O''Brien\\' WHERE id = E'1';''',
        r'''INSERT INTO public.people ("Name") VALUES (E'bob');''',
      ].join('\n'),
      'SELECT * FROM people',
    ]);
    // Read back, with nothing left to save.
    expect(find.text(_hint), findsOneWidget);
    expect(find.text('ann'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('running the query again drops what was not saved', (
    tester,
  ) async {
    final people = await _open(tester);

    await tester.tap(find.text('ann'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set NULL'));
    await tester.pumpAndSettle();
    expect(find.text('ann'), findsNothing);
    expect(find.text('1 change not saved'), findsOneWidget);

    // Its own value typed back is no change.
    await _type(tester, find.text('NULL').first, 'ann');
    expect(find.text(_hint), findsOneWidget);

    await _type(tester, find.text('ann'), 'zed');
    expect(find.text('zed'), findsOneWidget);
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(find.text('zed'), findsNothing);
    expect(find.text('ann'), findsOneWidget);
    expect(find.text(_hint), findsOneWidget);
    expect(people.runs, ['SELECT * FROM people', 'SELECT * FROM people']);
  });
}
