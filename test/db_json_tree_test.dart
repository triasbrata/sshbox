import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/ui/db_browser_page.dart';

/// A MongoDB whose every command finds one nested document.
class _Shops extends DbSession {
  @override
  String get hint => 'command';

  @override
  Future<Map<String, List<String>>> objects(String filter) async => {};

  @override
  Future<String> queryFor(String group, String name) async => '';

  @override
  Future<DbResult> run(String query) async {
    final document = {
      '_id': {r'$oid': '5f1d'},
      'name': 'shop',
      'owner': {
        'name': 'ann',
        'langs': ['dart', 'go'],
      },
      'many': [for (var i = 0; i < 150; i++) i],
    };
    return DbResult(
      columns: document.keys.toList(),
      rows: [
        [for (final value in document.values) jsonEncode(value)],
      ],
      note: '1 document',
      details: [const JsonEncoder.withIndent('  ').convert(document)],
    );
  }
}

void main() {
  testWidgets('a document\'s nested values open like a tree, a level at a '
      'time', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: DbBrowserPage(
          db: const DbConnection(
            id: 'shops',
            kind: DbKind.mongo,
            hostId: 'box',
            port: 27017,
          ),
          title: 'MongoDB on box',
          open: (db, {required confirmHostKey, required onSignIn}) async =>
              _Shops(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == 'command',
      ),
      '{"find": "shops"}',
    );
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('JSON'));
    await tester.pumpAndSettle();

    // The top level shows, each nested object or array as one closed line,
    // and an ObjectId as the one value it is.
    expect(find.textContaining('name: "shop"'), findsOneWidget);
    expect(find.textContaining(r'_id: {"$oid":"5f1d"}'), findsOneWidget);
    expect(find.text('owner  {2 keys}'), findsOneWidget);
    expect(find.text('many  [150 items]'), findsOneWidget);
    expect(find.textContaining('name: "ann"'), findsNothing);
    expect(find.byTooltip('Copy JSON'), findsOneWidget);

    await tester.tap(find.text('owner  {2 keys}'));
    await tester.pumpAndSettle();
    expect(find.textContaining('name: "ann"'), findsOneWidget);
    await tester.tap(find.text('langs  [2 items]'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0: "dart"'), findsOneWidget);
    expect(find.textContaining('1: "go"'), findsOneWidget);

    // A long array opens to its first hundred, and counts the rest.
    await tester.tap(find.text('many  [150 items]'));
    await tester.pumpAndSettle();
    expect(find.textContaining('99: 99', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('100: 100', skipOffstage: false), findsNothing);
    expect(
      find.textContaining('… 50 more', skipOffstage: false),
      findsOneWidget,
    );
  });
}
