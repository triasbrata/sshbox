import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/ui/db_browser_page.dart';

/// A database that counts how often its side list is read, and answers a
/// filter the way the real ones do.
class _Listed extends DbSession {
  _Listed(this.all, {this.cap});

  final Map<String, List<String>> all;

  /// As many names as a read stops at, like Redis's key scan; none if null.
  final int? cap;

  final reads = <String>[];

  @override
  String get hint => 'query';

  @override
  Future<Map<String, List<String>>> objects(String filter) async {
    reads.add(filter);
    final found = filterObjects(all, filter);
    final cap = this.cap;
    return cap == null
        ? found
        : {for (final e in found.entries) e.key: e.value.take(cap).toList()};
  }

  @override
  bool capped(Map<String, List<String>> objects) =>
      cap != null && (objects['']?.length ?? 0) >= cap!;

  @override
  Future<String> queryFor(String group, String name) async => '';

  @override
  Future<DbResult> run(String query) async =>
      const DbResult(columns: [], rows: []);
}

Future<void> _show(WidgetTester tester, DbKind kind, _Listed session) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: DbBrowserPage(
        db: DbConnection(id: 'db', kind: kind, hostId: 'box', port: 1),
        title: 'db',
        open: (db, {required confirmHostKey, required onSignIn}) async =>
            session,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _filter = find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      (widget.decoration?.hintText?.startsWith('Filter') ?? false),
);

void main() {
  testWidgets('the filter narrows the list read once, and only Refresh reads '
      'it again', (tester) async {
    final session = _Listed({
      'public': ['orders', 'people'],
      'audit': ['log'],
    });
    await _show(tester, DbKind.postgres, session);
    expect(session.reads, ['']);

    await tester.enterText(_filter, 'PEO');
    await tester.pump();
    expect(find.text('people'), findsOneWidget);
    expect(find.text('orders'), findsNothing);
    expect(find.text('log'), findsNothing);

    // A group's own name keeps all of it.
    await tester.enterText(_filter, 'aud');
    await tester.pump();
    expect(find.text('log'), findsOneWidget);
    expect(find.text('people'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    expect(session.reads, ['']);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(session.reads, ['', '']);
    expect(find.text('log'), findsOneWidget);
  });

  testWidgets('a Redis list cut short still asks the server when filtered', (
    tester,
  ) async {
    final session = _Listed({
      '': ['a1', 'a2', 'zz'],
    }, cap: 2);
    await _show(tester, DbKind.redis, session);
    expect(session.reads, ['']);
    expect(find.text('zz'), findsNothing);

    await tester.enterText(_filter, 'zz');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(session.reads, ['', 'zz']);
    expect(find.widgetWithText(ListTile, 'zz'), findsOneWidget);
  });
}
