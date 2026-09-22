import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/db/wire.dart';
import 'package:sshbox/src/ui/db_browser_page.dart';
import 'package:sshbox/src/ui/toast.dart';
import 'package:toastification/toastification.dart';

/// A database that keeps every command run and answers with one document,
/// editable or not as [edit] says.
class _Fake extends DbSession {
  _Fake({this.edit, this.readOnly});

  final DbEdit? edit;
  final String? readOnly;
  final runs = <String>[];

  @override
  String get hint => 'A database command, as JSON';

  @override
  Future<Map<String, List<DbObject>>> objects(
    String filter, {
    String? type,
  }) async => {
    'shop': [(name: 'customers', type: 'collection')],
  };

  @override
  Future<String> queryFor(String group, String name) async => '{"find": "$name"}';

  @override
  Future<DbResult> run(String query) async {
    runs.add(query);
    return DbResult(
      columns: const ['name'],
      rows: const [
        ['ann'],
      ],
      note: '1 document',
      edit: edit,
      readOnly: readOnly,
    );
  }
}

Future<_Fake> _open(WidgetTester tester, {DbKind kind = DbKind.mongo, _Fake? db}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = db ?? _Fake();
  await tester.pumpWidget(
    ToastificationWrapper(
      config: toastConfig,
      child: MaterialApp(
        builder: (context, child) => ToastLayer(child: child!),
        home: DbBrowserPage(
          db: DbConnection(id: 'db', kind: kind, hostId: 'box', port: 27017),
          title: 'A database on box',
          open: (_, {required confirmHostKey, required onSignIn}) async => session,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return session;
}

void main() {
  group('the command a tab builds', () {
    test('find takes the fields Compass gives, and leaves out the blanks', () {
      final command = jsonDecode(
        mongoFindCommand(
          db: 'shop',
          collection: 'customers',
          filter: '{"city": "Bandung"}',
          sort: '{"name": 1}',
          limit: '20',
        ),
      );
      expect(command, {
        'find': 'customers',
        'filter': {'city': 'Bandung'},
        'sort': {'name': 1},
        'limit': 20,
        r'$db': 'shop',
      });
    });

    test('find with nothing typed asks for every document', () {
      expect(jsonDecode(mongoFindCommand(db: 'shop', collection: 'customers')), {
        'find': 'customers',
        'filter': <String, Object?>{},
        r'$db': 'shop',
      });
    });

    test('a field that is not JSON says which, before anything is sent', () {
      expect(
        () => mongoFindCommand(
          db: 'shop',
          collection: 'customers',
          filter: '{city: Bandung}',
        ),
        throwsA(
          isA<DbException>().having((e) => '$e', 'says', contains('Filter')),
        ),
      );
      expect(
        () => mongoFindCommand(
          db: 'shop',
          collection: 'customers',
          project: '["name"]',
        ),
        throwsA(
          isA<DbException>().having(
            (e) => '$e',
            'says',
            contains('Project is a JSON object'),
          ),
        ),
      );
      expect(
        () => mongoFindCommand(
          db: 'shop',
          collection: 'customers',
          limit: 'ten',
        ),
        throwsA(
          isA<DbException>().having((e) => '$e', 'says', contains('Limit')),
        ),
      );
    });

    test('with no collection picked it says to pick one', () {
      expect(
        () => mongoFindCommand(db: 'shop', collection: ''),
        throwsA(
          isA<DbException>().having(
            (e) => '$e',
            'says',
            contains('Tap a collection'),
          ),
        ),
      );
    });

    test('aggregate keeps the stages in order, and asks for a cursor', () {
      final command = jsonDecode(
        mongoAggregateCommand(
          db: 'shop',
          collection: 'customers',
          stages: [r'{"$match": {"active": true}}', r'{"$count": "n"}'],
        ),
      );
      expect(command, {
        'aggregate': 'customers',
        'pipeline': [
          {r'$match': {'active': true}},
          {r'$count': 'n'},
        ],
        'cursor': <String, Object?>{},
        r'$db': 'shop',
      });
    });

    test('a stage that does not read says which one', () {
      expect(
        () => mongoAggregateCommand(
          db: 'shop',
          collection: 'customers',
          stages: [r'{"$match": {}}', '{oops}'],
        ),
        throwsA(
          isA<DbException>().having((e) => '$e', 'says', contains('Stage 2')),
        ),
      );
    });
  });

  testWidgets('MongoDB is asked by tab, and other databases are not', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('Find'), findsOneWidget);
    expect(find.text('Aggregate'), findsOneWidget);
    expect(find.text('Command'), findsOneWidget);

    await _open(tester, kind: DbKind.postgres);
    expect(find.text('Find'), findsNothing);
    expect(find.text('Aggregate'), findsNothing);
  });

  testWidgets('a collection tapped fills Find, and Run sends it', (
    tester,
  ) async {
    final db = await _open(tester);
    await tester.tap(find.text('customers'));
    await tester.pumpAndSettle();

    expect(find.text('shop.customers'), findsOneWidget);
    expect(db.runs.single, contains('"find": "customers"'));
    expect(db.runs.single, contains('"limit": 50'));

    await tester.enterText(find.widgetWithText(TextField, 'Filter'), '{"city": "Bandung"}');
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(jsonDecode(db.runs.last), {
      'find': 'customers',
      'filter': {'city': 'Bandung'},
      'limit': 50,
      r'$db': 'shop',
    });
  });

  testWidgets('a pipeline is built stage by stage and run', (tester) async {
    final db = await _open(tester);
    await tester.tap(find.text('customers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aggregate'));
    await tester.pumpAndSettle();
    expect(find.text('No stages yet: add one below.'), findsOneWidget);

    await tester.tap(find.text('Add stage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(r'$match').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Stage 1'),
      r'{"$count": "n"}',
    );
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(jsonDecode(db.runs.last), {
      'aggregate': 'customers',
      'pipeline': [
        {r'$count': 'n'},
      ],
      'cursor': <String, Object?>{},
      r'$db': 'shop',
    });
  });

  testWidgets("an aggregate's rows cannot be edited, and the grid says so", (
    tester,
  ) async {
    const why = 'Read-only: a pipeline works its rows out';
    await _open(tester, db: _Fake(readOnly: why));
    await tester.tap(find.text('customers'));
    await tester.pumpAndSettle();

    expect(find.text('Tap a cell to edit it, hold a row to delete it'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && (widget.message ?? '').startsWith(why),
      ),
      findsOneWidget,
    );
  });

  testWidgets('changes not saved are asked about before another tab shows', (
    tester,
  ) async {
    final db = await _open(
      tester,
      db: _Fake(
        edit: DbEdit((changes) async => null),
      ),
    );
    await tester.tap(find.text('customers'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ann'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'bob');
    await tester.tap(find.bySemanticsLabel('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Aggregate'));
    await tester.pumpAndSettle();
    expect(find.text('Discard 1 change?'), findsOneWidget);

    // Kept: the tab does not change behind the question.
    await tester.tap(find.bySemanticsLabel('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Filter'), findsOneWidget);
    expect(db.runs, hasLength(1));
  });
}
