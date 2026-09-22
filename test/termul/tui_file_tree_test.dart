import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/termul/tui_file_tree.dart';
import 'package:sshbox/src/ui/termul/termul_palette.dart';
import 'package:sshbox/src/ui/termul/termul_theme.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TermulTheme.of(TermulPalette.mocha),
        home: Scaffold(body: SizedBox(width: 280, height: 400, child: child)),
      ),
    );
  }

  test('tuiFileTreeFlatten expands open folders', () {
    final nodes = tuiFileTreeFlatten(
      roots: const [
        TuiFileNode(id: '/a', name: 'a', kind: TuiFileKind.folder),
        TuiFileNode(id: '/b.txt', name: 'b.txt', kind: TuiFileKind.file),
      ],
      expanded: {'/a'},
      childrenOf: (id) => id == '/a'
          ? const [
              TuiFileNode(
                id: '/a/c.dart',
                name: 'c.dart',
                kind: TuiFileKind.file,
              ),
            ]
          : const [],
    );
    expect(nodes.map((n) => n.name), ['a', 'c.dart', 'b.txt']);
    expect(nodes[1].depth, 1);
  });

  testWidgets('renders explorer chrome and selection', (tester) async {
    String? selected;
    await pumpHost(
      tester,
      TuiFileTree(
        title: 'host',
        rootLabel: 'home',
        selectedId: '/readme',
        nodes: const [
          TuiFileNode(id: '/src', name: 'src', kind: TuiFileKind.folder),
          TuiFileNode(id: '/readme', name: 'README.md', kind: TuiFileKind.file),
        ],
        onSelect: (n) => selected = n.id,
        onNewFile: () {},
        onRefresh: () {},
      ),
    );

    expect(find.textContaining('EXPLORER'), findsOneWidget);
    expect(find.textContaining('host'), findsOneWidget);
    expect(find.text('HOME'), findsOneWidget);
    expect(find.text('src'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);

    await tester.tap(find.text('src'));
    expect(selected, '/src');
  });

  testWidgets('empty and error states', (tester) async {
    await pumpHost(
      tester,
      const TuiFileTree(nodes: [], emptyMessage: 'Empty folder'),
    );
    expect(find.text('Empty folder'), findsOneWidget);

    await pumpHost(
      tester,
      TuiFileTree(
        nodes: const [],
        errorMessage: 'Permission denied',
        onRefresh: () {},
      ),
    );
    expect(find.text('Permission denied'), findsOneWidget);
    expect(find.text('retry'), findsOneWidget);
  });

  testWidgets('folder shows loading glyph', (tester) async {
    await pumpHost(
      tester,
      const TuiFileTree(
        nodes: [
          TuiFileNode(
            id: '/x',
            name: 'x',
            kind: TuiFileKind.folder,
            loading: true,
          ),
        ],
      ),
    );
    expect(find.text('…'), findsOneWidget);
  });
}
