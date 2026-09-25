import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_data_grid.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, {required Widget under}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.paper),
        home: Scaffold(body: SizedBox(height: 400, width: 600, child: under)),
      ),
    );
  }

  testWidgets('grid renders headers, NULL, dirty and deleted', (tester) async {
    await pumpHost(
      tester,
      under: TuiDataGrid(
        columns: const [
          TuiDataGridColumn(id: 'id', label: 'id', width: 80),
          TuiDataGridColumn(id: 'email', label: 'email', width: 160),
        ],
        rows: const [
          TuiDataGridRow(
            id: '1',
            cells: [
              TuiDataGridCell(value: '1'),
              TuiDataGridCell(value: 'ada@termul.dev', dirty: true),
            ],
          ),
          TuiDataGridRow(
            id: '2',
            cells: [
              TuiDataGridCell(value: '2'),
              TuiDataGridCell(value: null),
            ],
          ),
          TuiDataGridRow(
            id: '3',
            deleted: true,
            cells: [
              TuiDataGridCell(value: '3'),
              TuiDataGridCell(value: 'old@termul.dev'),
            ],
          ),
        ],
      ),
    );

    expect(find.text('id'), findsOneWidget);
    expect(find.text('email'), findsOneWidget);
    expect(find.text('ada@termul.dev'), findsOneWidget);
    expect(find.text('NULL'), findsOneWidget);
    expect(find.text('old@termul.dev'), findsOneWidget);
  });

  testWidgets('error banner shows', (tester) async {
    await pumpHost(
      tester,
      under: const TuiDataGrid(
        columns: [TuiDataGridColumn(id: 'id', label: 'id')],
        rows: [],
        errorBanner: 'relation "users" does not exist',
      ),
    );

    expect(find.text('relation "users" does not exist'), findsOneWidget);
  });

  testWidgets('cell tap reports coordinates', (tester) async {
    (int, int)? tapped;
    await pumpHost(
      tester,
      under: TuiDataGrid(
        columns: const [
          TuiDataGridColumn(id: 'a', label: 'a', width: 100),
          TuiDataGridColumn(id: 'b', label: 'b', width: 100),
        ],
        rows: const [
          TuiDataGridRow(
            id: '1',
            cells: [
              TuiDataGridCell(value: 'x'),
              TuiDataGridCell(value: 'y'),
            ],
          ),
        ],
        onCellTap: (r, c) => tapped = (r, c),
      ),
    );

    await tester.tap(find.text('y'));
    expect(tapped, (0, 1));
  });

  testWidgets('json tree expands nested objects', (tester) async {
    await pumpHost(
      tester,
      under: const SingleChildScrollView(
        child: TuiJsonTree(
          value: {
            'email': 'ada@termul.dev',
            'meta': {'devices': 2},
          },
        ),
      ),
    );

    expect(find.textContaining('email'), findsWidgets);
    expect(find.textContaining('Object(1)'), findsOneWidget);

    await tester.tap(find.textContaining('meta'));
    await tester.pumpAndSettle();
    expect(find.textContaining('devices'), findsOneWidget);
    expect(find.textContaining('2'), findsOneWidget);
  });

  testWidgets('json card shows index and copy', (tester) async {
    var copied = false;
    await pumpHost(
      tester,
      under: SingleChildScrollView(
        child: TuiJsonCard(
          index: 1,
          data: const {'ok': true},
          onCopy: () => copied = true,
        ),
      ),
    );

    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.text('⎘'));
    expect(copied, isTrue);
  });

  testWidgets('mongo \$ wrappers stay scalar', (tester) async {
    await pumpHost(
      tester,
      under: const SingleChildScrollView(
        child: TuiJsonNode(name: '_id', value: {r'$oid': '66f1'}),
      ),
    );

    // Not an expandable Object(1) branch.
    expect(find.textContaining('Object('), findsNothing);
    expect(find.textContaining(r'$oid'), findsOneWidget);
  });
}
