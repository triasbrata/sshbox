import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/db/db_session.dart';
import 'package:sshbox/src/db/redis.dart';
import 'package:sshbox/src/ui/db_browser_page.dart';
import 'package:sshbox/src/ui/tui.dart';

/// A [kind] of database that keeps each read of its side list, and answers
/// a filter the way the real ones do. Each name is a table, a collection or
/// a string, unless [types] says otherwise.
class _Listed extends DbSession {
  _Listed(
    this.kind,
    Map<String, List<String>> names, {
    this.cap,
    Map<String, String> types = const {},
  }) : all = {
         for (final MapEntry(key: group, value: names) in names.entries)
           group: [
             for (final name in names)
               (
                 name: name,
                 type:
                     types[name] ??
                     switch (kind) {
                       DbKind.postgres => 'BASE TABLE',
                       DbKind.mongo => 'collection',
                       DbKind.redis => 'string',
                     },
               ),
           ],
       };

  final DbKind kind;
  final Map<String, List<DbObject>> all;

  /// As many names as a read stops at, like Redis's key scan; none if null.
  final int? cap;

  /// Each read's filter, and its type.
  final reads = <String>[];
  final typesRead = <String?>[];

  @override
  String get hint => 'query';

  @override
  Future<Map<String, List<DbObject>>> objects(
    String filter, {
    String? type,
  }) async {
    reads.add(filter);
    typesRead.add(type);
    final found = filterObjects(kind, all, filter, type: type);
    final cap = this.cap;
    return cap == null
        ? found
        : {for (final e in found.entries) e.key: e.value.take(cap).toList()};
  }

  @override
  bool capped(Map<String, List<DbObject>> objects) =>
      cap != null && (objects['']?.length ?? 0) >= cap!;

  @override
  Future<String> queryFor(String group, String name) async => '';

  @override
  Future<DbResult> run(String query) async =>
      const DbResult(columns: [], rows: []);
}

Future<void> _show(WidgetTester tester, _Listed session) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: DbBrowserPage(
        db: DbConnection(id: 'db', kind: session.kind, hostId: 'box', port: 1),
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

/// The type chip labelled [label].
/// termul's chip reading [label]: its name, and its count after it.
Finder _chip(String label) => find.byWidgetPredicate(
  (w) =>
      w is TuiFilterChip &&
      [w.label, if (w.count case final count?) '$count'].join(' ') == label,
);

void main() {
  testWidgets('the filter narrows the list read once, and only Refresh reads '
      'it again', (tester) async {
    final session = _Listed(DbKind.postgres, {
      'public': ['orders', 'people'],
      'audit': ['log'],
    });
    await _show(tester, session);
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
    final session = _Listed(DbKind.redis, {
      '': ['a1', 'a2', 'zz'],
    }, cap: 2);
    await _show(tester, session);
    expect(session.reads, ['']);
    expect(find.text('zz'), findsNothing);

    await tester.enterText(_filter, 'zz');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(session.reads, ['', 'zz']);
    expect(find.widgetWithText(ListTile, 'zz'), findsOneWidget);
  });

  testWidgets('SQL view: schema.table narrows to that schema', (tester) async {
    final session = _Listed(DbKind.postgres, {
      'public': ['log', 'people'],
      'audit': ['log'],
    });
    await _show(tester, session);
    await tester.enterText(_filter, 'audit.lo');
    await tester.pump();
    expect(find.text('audit'), findsOneWidget);
    expect(find.text('log'), findsOneWidget);
    expect(find.text('public'), findsNothing);
  });

  testWidgets('SQL view: a chip for each kind of table listed, and schemas '
      'that fold', (tester) async {
    final session = _Listed(
      DbKind.postgres,
      {
        'public': ['orders', 'people_v', 'totals'],
        'audit': ['log'],
      },
      types: {'people_v': 'VIEW', 'totals': 'MATERIALIZED VIEW'},
    );
    await _show(tester, session);
    expect(_chip('Tables 2'), findsOneWidget);
    expect(_chip('Views 1'), findsOneWidget);
    expect(_chip('Materialized views 1'), findsOneWidget);
    // None of those here, so no chip for them.
    expect(find.textContaining('Foreign'), findsNothing);

    await tester.tap(_chip('Views 1'));
    await tester.pump();
    expect(find.text('people_v'), findsOneWidget);
    expect(find.text('orders'), findsNothing);
    expect(find.text('audit'), findsNothing);

    await tester.tap(_chip('Views 1'));
    await tester.pump();
    expect(find.text('orders'), findsOneWidget);
    expect(find.text('log'), findsOneWidget);

    // A schema folds to its name, and opens again.
    await tester.tap(find.text('public'));
    await tester.pump();
    expect(find.text('orders'), findsNothing);
    expect(find.text('log'), findsOneWidget);
    // A filter shows what it matches, folded or not.
    await tester.enterText(_filter, 'ord');
    await tester.pump();
    expect(find.text('orders'), findsOneWidget);
    await tester.enterText(_filter, '');
    await tester.pump();
    expect(find.text('orders'), findsNothing);
    await tester.tap(find.text('public'));
    await tester.pump();
    expect(find.text('orders'), findsOneWidget);

    // All of it in memory: nothing asked of the database.
    expect(session.reads, ['']);
  });

  testWidgets('NoSQL view: database.collection narrows to that database', (
    tester,
  ) async {
    final session = _Listed(DbKind.mongo, {
      'jeansh': ['people'],
      'shop': ['people', 'orders'],
    });
    await _show(tester, session);
    await tester.enterText(_filter, 'shop.peo');
    await tester.pump();
    expect(find.text('shop'), findsOneWidget);
    expect(find.text('people'), findsOneWidget);
    expect(find.text('jeansh'), findsNothing);
  });

  testWidgets('NoSQL view: a collection keeps its database in sight, a '
      'database keeps its collections, and views have a chip', (tester) async {
    final session = _Listed(
      DbKind.mongo,
      {
        'jeansh': ['people'],
        'shop': ['orders', 'rich'],
      },
      types: {'rich': 'view'},
    );
    await _show(tester, session);

    await tester.enterText(_filter, 'ord');
    await tester.pump();
    expect(find.text('shop'), findsOneWidget);
    expect(find.text('orders'), findsOneWidget);
    expect(find.text('rich'), findsNothing);

    await tester.enterText(_filter, 'sho');
    await tester.pump();
    expect(find.text('orders'), findsOneWidget);
    expect(find.text('rich'), findsOneWidget);
    expect(find.text('people'), findsNothing);

    await tester.enterText(_filter, '');
    await tester.tap(_chip('Views 1'));
    await tester.pump();
    expect(find.text('rich'), findsOneWidget);
    expect(find.text('orders'), findsNothing);
    expect(find.text('jeansh'), findsNothing);
    expect(session.reads, ['']);
  });

  testWidgets('KV view: a glob pattern matches keys as SCAN MATCH does', (
    tester,
  ) async {
    final session = _Listed(DbKind.redis, {
      '': ['superuser:1', 'user:1', 'user:22', 'session:ab:x'],
    });
    await _show(tester, session);
    await tester.enterText(_filter, 'user:?');
    await tester.pump();
    expect(find.text('user:1'), findsOneWidget);
    expect(find.text('user:22'), findsNothing);
    expect(find.text('superuser:1'), findsNothing);
  });

  testWidgets('KV view: each key shows its type, and a type chip narrows to '
      'it', (tester) async {
    final session = _Listed(
      DbKind.redis,
      {
        '': ['cart:1', 'user:1', 'user:2'],
      },
      types: {'user:1': 'hash', 'user:2': 'hash', 'cart:1': 'zset'},
    );
    await _show(tester, session);
    expect(find.widgetWithText(ListTile, 'zset'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'hash'), findsNWidgets(2));
    expect(_chip('Hash 2'), findsOneWidget);
    expect(_chip('Sorted set 1'), findsOneWidget);
    // Nothing of those here.
    expect(_chip('Stream'), findsNothing);

    await tester.tap(_chip('Sorted set 1'));
    await tester.pump();
    expect(find.text('cart:1'), findsOneWidget);
    expect(find.text('user:1'), findsNothing);
    expect(session.reads, ['']);
  });

  testWidgets('KV view: past the cap, a type goes to the server with the '
      'pattern', (tester) async {
    final session = _Listed(
      DbKind.redis,
      {
        '': ['a1', 'a2', 'h1', 'zz'],
      },
      cap: 2,
      types: {'h1': 'hash'},
    );
    await _show(tester, session);
    expect(find.textContaining('Too many keys'), findsOneWidget);
    expect(find.text('h1'), findsNothing);
    // Every type is offered, since the ones past the cap are not known.
    expect(_chip('Stream'), findsOneWidget);

    await tester.tap(_chip('Hash'));
    await tester.pumpAndSettle();
    expect(session.reads, ['', '']);
    expect(session.typesRead, [null, 'hash']);
    expect(find.text('h1'), findsOneWidget);

    await tester.enterText(_filter, 'h*');
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(session.reads.last, 'h*');
    expect(session.typesRead.last, 'hash');
    expect(find.text('h1'), findsOneWidget);
  });

  test('a Redis pattern matches as SCAN MATCH does, byte for byte', () {
    expect(redisPattern(''), '*');
    expect(redisPattern(' user '), '*user*');
    expect(redisPattern('user:*'), 'user:*');
    expect(redisPattern(r'a\b'), r'a\b');

    final cases = {
      ('user:*', 'user:1'): true,
      ('user:*', 'superuser:1'): false,
      ('session:??:*', 'session:ab:x'): true,
      ('session:??:*', 'session:abc:x'): false,
      ('[ab]*', 'apple'): true,
      ('[^ab]*', 'apple'): false,
      ('[a-c]x', 'bx'): true,
      ('[c-a]x', 'bx'): true,
      ('[a-c]x', 'dx'): false,
      (r'\*', '*'): true,
      (r'\*', 'a'): false,
      (r'[\]]', ']'): true,
      // é is two bytes, as Redis counts them.
      ('h?llo', 'héllo'): false,
      ('h??llo', 'héllo'): true,
      ('*', ''): true,
      ('a*', 'a'): true,
      ('*a*b*c', 'xxaxxbxxc'): true,
      ('*a*b*c', 'xxaxxbxxd'): false,
      // A class never closed matches nothing, as in Redis.
      ('a[', 'a['): false,
    };
    cases.forEach((c, expected) {
      expect(redisMatch(c.$1, c.$2), expected, reason: '${c.$1} ~ ${c.$2}');
    });
  });
}
