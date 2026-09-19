import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/ui/db_browser_page.dart';
import 'package:sshbox/src/ui/toast.dart';
import 'package:toastification/toastification.dart';

/// A database whose every run reads the same [rows] back, saved through
/// [edit], and which keeps every query run.
class _Fake extends DbSession {
  _Fake(this.columns, this.rows, this.edit);

  final List<String> columns;
  final List<List<String?>> rows;
  final DbEdit edit;
  final runs = <String>[];

  @override
  String get hint => 'query';

  @override
  Future<Map<String, List<DbObject>>> objects(
    String filter, {
    String? type,
  }) async => {};

  @override
  Future<String> queryFor(String group, String name) async => '';

  @override
  Future<DbResult> run(String query) async {
    runs.add(query);
    return DbResult(columns: columns, rows: rows, note: 'read', edit: edit);
  }
}

const _hint = 'Tap a cell to edit it, hold a row to delete it';
const _query = 'SELECT * FROM people';

/// A PostgreSQL table of two people, each save's SQL kept in [saved].
_Fake _people(List<String> saved) {
  final rows = [
    ['1', 'ann'],
    ['2', null],
  ];
  const table = DbTable(
    name: 'public.people',
    columns: ['id', '"Name"'],
    key: [0],
  );
  return _Fake(
    ['id', 'name'],
    rows,
    DbEdit((changes) async {
      saved.add(changes.sql(table, rows));
      return null;
    }),
  );
}

Future<void> _open(WidgetTester tester, DbSession db) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // Wrapped the way the app wraps its pages, so a toast shows.
  await tester.pumpWidget(
    ToastificationWrapper(
      config: toastConfig,
      child: MaterialApp(
        builder: (context, child) => ToastLayer(child: child!),
        home: DbBrowserPage(
          db: const DbConnection(
            id: 'db',
            kind: DbKind.postgres,
            hostId: 'box',
            port: 5432,
          ),
          title: 'A database on box',
          open: (_, {required confirmHostKey, required onSignIn}) async => db,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == 'query',
    ),
    _query,
  );
  await tester.tap(find.text('Run'));
  await tester.pumpAndSettle();
}

/// The button saying [label] on the dialog, not the one behind it.
Finder _inDialog(String label) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(label));

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
    final saved = <String>[];
    final db = _people(saved);
    await _open(tester, db);
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
    expect(saved, [
      [
        r"DELETE FROM public.people WHERE id = E'2';",
        r'''UPDATE public.people SET "Name" = E'O''Brien\\' WHERE id = E'1';''',
        r'''INSERT INTO public.people ("Name") VALUES (E'bob');''',
      ].join('\n'),
    ]);
    // Read back, with nothing left to save.
    expect(db.runs, [_query, _query]);
    expect(find.text(_hint), findsOneWidget);
    expect(find.text('ann'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('running the query again drops what was not saved', (
    tester,
  ) async {
    final saved = <String>[];
    final db = _people(saved);
    await _open(tester, db);

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
    // Asked first, the run reading the rows afresh.
    expect(find.text('Discard 1 change?'), findsOneWidget);
    await tester.tap(_inDialog('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('zed'), findsNothing);
    expect(find.text('ann'), findsOneWidget);
    expect(find.text(_hint), findsOneWidget);
    expect(saved, isEmpty);
    expect(db.runs, [_query, _query]);
  });

  testWidgets('nothing not saved goes without asking', (tester) async {
    final saved = <String>[];
    final db = _people(saved);
    await _open(tester, db);
    await _type(tester, find.text('ann'), 'zed');

    // A run reads the rows afresh: Keep editing leaves the change where it
    // is, and runs nothing.
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(find.text('Discard 1 change?'), findsOneWidget);
    await tester.tap(_inDialog('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('zed'), findsOneWidget);
    expect(db.runs, [_query]);

    // A reconnect would let the rows go too.
    await tester.tap(find.byTooltip('Reconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Discard 1 change?'), findsOneWidget);
    await tester.tap(_inDialog('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('zed'), findsOneWidget);
    expect(saved, isEmpty);
  });

  testWidgets('a locked column is not edited, no NULL where there is none, '
      'and a save made in part is said and read back', (tester) async {
    // A Redis list: its place is no value, and it holds no NULL.
    final db = _Fake(
      ['#', 'value'],
      [
        ['1', 'x'],
      ],
      DbEdit(
        (changes) async => 'WRONGTYPE nope',
        locked: {0},
        nulls: false,
        unset: '',
      ),
    );
    await _open(tester, db);

    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    await tester.tap(find.text('x'));
    await tester.pumpAndSettle();
    expect(find.text('Set NULL'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await _type(tester, find.text('x'), 'y');
    expect(find.text('1 change not saved'), findsOneWidget);

    await tester.tap(find.text('Save'));
    // A frame for the toasts' overlay, one to start the slide, and the slide.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // Said before the toast closes itself.
    expect(find.textContaining('WRONGTYPE nope'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('x'), findsOneWidget);
    expect(find.text(_hint), findsOneWidget);
    expect(db.runs, [_query, _query]);
    await tester.pump(const Duration(seconds: 5));
  });
}
